import { defineConfig } from 'stepai-vite-config'
import type { Plugin } from 'vite'
import { inlineStartupStyles } from './startup-vite'
import { fromRoot, sharedViteConfig } from './vite.shared'

/* -----------------------------------------------------------------------------
 * 开发期原生能力缺口上报（仅 dev）
 *
 * 浏览器预览里没有 App 壳：原生能力要么由 mock 模拟、要么根本没实现。
 * 桥接层（src/shared/bridge/dev-report.ts）把这两类情况 POST 到下面这个端点，
 * 由中间件打印到 DevServer 终端，提醒开发者「该能力必须到真机验证」。
 *
 * `apply: 'serve'` 保证只在 vite dev 装配；vite build 不会包含本插件，
 * 产物里也不会有任何上报逻辑（门禁 G39 会检查）。
 * -------------------------------------------------------------------------- */

const NATIVE_REPORT_PATH = '/__ai-builder/native-report'

interface NativeReportPayload {
  level?: 'notice' | 'warn'
  key?: string
  message?: string
  detail?: string
}

function formatNativeReport(payload: NativeReportPayload): string {
  const isWarn = payload.level === 'warn'
  return [
    `[native] ${isWarn ? '⚠ 原生能力缺口' : 'ℹ 预览环境提示'}：${payload.message ?? ''}`,
    payload.detail ? `         ${payload.detail}` : '',
    isWarn
      ? '         真机验证：该能力在 Web 预览里无法验证，请到 App 壳（真机）内测试。'
      : '         真机验收：预览返回的是模拟值，请到 App 壳（真机）内确认真实行为。',
  ]
    .filter(Boolean)
    .join('\n')
}

function nativeDevReportPlugin(): Plugin {
  const printed = new Set<string>()
  return {
    name: 'ai-builder:native-dev-report',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use(NATIVE_REPORT_PATH, (req, res) => {
        if (req.method !== 'POST') {
          res.statusCode = 405
          res.end()
          return
        }
        let body = ''
        req.setEncoding('utf8')
        req.on('data', (chunk: string) => {
          body += chunk
        })
        req.on('end', () => {
          res.statusCode = 204
          res.end()
          let payload: NativeReportPayload
          try {
            payload = JSON.parse(body) as NativeReportPayload
          } catch {
            return
          }
          const key = payload.key ?? payload.message
          // 同一条信息只打印一次，避免页面反复调用时刷屏
          if (!key || printed.has(key)) return
          printed.add(key)
          server.config.logger.warn(formatNativeReport(payload))
        })
      })
    },
  }
}

/* -----------------------------------------------------------------------------
 * 桥接 SDK 注入（仅构建 App UI，dev 不注入）
 *
 * 壳提供的桥接 SDK `/sdk/capsule.js` 只在壳内可达：浏览器 / 平台预览没有它，静态写在
 * index.html 里会 404。所以源工程 index.html 不引入它，改由本插件在构建时写进产物 HTML
 * （`dist/client/web/index.html`）——`apply: 'build'` 保证 devServer 那条链路不受影响，
 * 预览里桥接层照旧回落 mock（见 src/shared/bridge/loader.ts）。
 *
 * Admin UI 用 vite.config.admin.ts，不装本插件，产物里不带这一行（后台不调端能力）。
 * 产物侧由 finalize-build.mjs 与门禁 G40 校验（口径见 references/10-webview-runtime.md）。
 * -------------------------------------------------------------------------- */

const CAPSULE_SDK_SRC = '/sdk/capsule.js'

/** 语义同 finalize-build.mjs / validate.mjs 的产物校验：源码里若已写回该 `<script src>`，就不再重复注入。 */
const CAPSULE_SDK_TAG = new RegExp(
  `<script\\b[^>]*\\bsrc\\s*=\\s*["']${CAPSULE_SDK_SRC.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}["']`,
  'i',
)

function capsuleSdkInjectPlugin(): Plugin {
  return {
    name: 'ai-builder:capsule-sdk-inject',
    apply: 'build',
    transformIndexHtml(html) {
      // 幂等：源码被改回静态引入时只保留它自己那一份，不叠第二条
      // （capsule.js 自身有 __ready 去重，但重复请求本身没必要）。
      if (CAPSULE_SDK_TAG.test(html)) return []
      return [
        {
          tag: 'script',
          attrs: { src: CAPSULE_SDK_SRC },
          injectTo: 'body',
        },
      ]
    },
  }
}

/**
 * App UI（移动端 H5）的开发与构建配置。
 *
 * dev：一个 DevServer 同时服务两个入口 —— `/`（App UI）、`/admin.html`（Admin UI）。
 *      壳应用做真机预览时直接连这个 DevServer，所以 Admin UI 不需要单独起服务。
 * build：只产出 App UI，输出到 `dist/client/web/`（`capsule/manifest.json` 的 `entry` 指向它）；
 *      同级的 `manifest.json` / `signing/` / `icon/` 由 scripts/finalize-build.mjs 从 capsule/ 补齐。
 *
 * 开发预览 / 源码定位 / 元素点选 / 错误采集由 stepai-vite-config 统一接入，
 * 只在 vite.config.ts 配置一次，应用入口不要 import runtime。
 * 详见 references/01-tech-stack.md 与 references/02-iterability-contract.md。
 */
export default defineConfig({
  outputDir: 'dist/client/web',
  vite: {
    ...sharedViteConfig,
    plugins: [...(sharedViteConfig.plugins ?? []), nativeDevReportPlugin(), capsuleSdkInjectPlugin(), inlineStartupStyles()],
    server: {
      host: '127.0.0.1',
      port: 5173,
      strictPort: false,
      allowedHosts: true,
      // 关闭 Vite 的错误浮层：预览在平台 UI 里渲染，浮层会被当成平台界面的一部分，
      // 污染用户看到的效果；构建 / 运行错误仍照常打到 DevServer 终端。
      hmr: { overlay: false }
    },
    build: {
      ...sharedViteConfig.build,
      rollupOptions: {
        // 单入口：Admin UI 由 vite.config.admin.ts 单独构建，两边不共享 chunk
        input: { app: fromRoot('./index.html') },
      },
    },
  },
  sourceLocator: true,
  previewRuntime: true,
  errorCollector: true,
  context: {
    projectId: process.env.STEPAI_PROJECT_ID ?? 'ai-builder-app',
    sessionId: process.env.STEPAI_SESSION_ID ?? 'local-preview',
    commitSha: process.env.STEPAI_COMMIT_SHA ?? 'baseline',
    hostOrigin: process.env.STEPAI_HOST_ORIGIN ?? 'http://127.0.0.1:4173',
  },
})
