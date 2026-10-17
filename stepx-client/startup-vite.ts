import { posix } from 'node:path'
import type { Plugin } from 'vite'

/** Keep the built entry's stylesheet available before the first paint. */
export function inlineStartupStyles(): Plugin {
  return {
    name: 'apt:inline-startup-styles',
    apply: 'build',
    transformIndexHtml: {
      order: 'post',
      handler(html, context) {
        const bundle = context.bundle
        if (!bundle) throw new Error('APT startup styles require the production bundle')
        return html.replace(/<link\b[^>]*\brel=["']stylesheet["'][^>]*>/gi, tag => {
          const href = /\bhref=["']([^"']+)["']/i.exec(tag)?.[1]
          const name = href?.replace(/^\.\//, '')
          const asset = name && bundle[name]
          if (!name || !asset || asset.type !== 'asset') throw new Error('APT entry stylesheet is not in the local bundle')
          const source = typeof asset.source === 'string' ? asset.source : new TextDecoder().decode(asset.source)
          // A CSS asset moves from assets/ into HTML; retain relative resource URLs.
          const css = source.replace(/url\(\s*(["']?)([^"')]+)\1\s*\)/gi, (full, quote: string, url: string) => {
            if (/^(?:[a-z][a-z\d+.-]*:|\/|#)/i.test(url)) return full
            return `url(${quote}${posix.join(posix.dirname(name), url.trim())}${quote})`
          })
          return `<style data-apt-entry-css="${name}">${css.replace(/<\/style/gi, '<\\/style')}</style>`
        })
      },
    },
  }
}
