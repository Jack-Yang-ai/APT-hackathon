import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
function fixture() {
  const c = {}; vm.createContext(c);
  const source = fs.readFileSync(new URL('../src/ui/returnTo.ts', import.meta.url), 'utf8').replace(/export /g, '');
  vm.runInContext(stripTypeScriptTypes(source) + '\nglobalThis.api={rememberBusinessPath,getReturnTo,businessTab,getTabPath,parentPage,backPage,isBusinessPath,savePageScroll,pageScroll};', c);return c.api;
}
test('calendar and event transcript return to their originating tab and preserve independent tab paths', () => {
  const a = fixture(); a.rememberBusinessPath('/me'); a.rememberBusinessPath('/days/1000'); a.rememberBusinessPath('/events/r%3A1');
  a.rememberBusinessPath('/events/r%3A1/transcript'); assert.equal(a.businessTab(a.getReturnTo()), '/me');
  a.rememberBusinessPath('/actions'); a.rememberBusinessPath('/actions/a'); assert.equal(a.getTabPath('/me'), '/events/r%3A1/transcript');
  assert.equal(a.getTabPath('/actions'), '/actions/a'); assert.equal(a.parentPage('/events/r%3A1/transcript'), '/events/r%3A1');
  assert.equal(a.parentPage('/days/1000'), '/me'); assert.equal(a.parentPage('/actions/a'), '/actions');
});
test('restoring a tab carries its origin and back chain after another tab opened a detail', () => {
  const a = fixture(); a.rememberBusinessPath('/'); a.rememberBusinessPath('/events/r%3A1');
  a.savePageScroll('/events/r%3A1', 140, '/'); a.rememberBusinessPath('/me'); a.rememberBusinessPath('/me/backscreen');
  const restored = a.getTabPath('/'); assert.equal(a.businessTab(restored, '/'), '/');
  a.rememberBusinessPath(restored, '/'); assert.equal(a.getTabPath('/me'), '/me/backscreen');
  assert.equal(a.backPage(restored, '/'), '/');
  a.rememberBusinessPath(a.backPage(restored, '/'), '/'); assert.equal(a.getTabPath('/'), '/');
  const me = a.getTabPath('/me'); a.rememberBusinessPath(me, '/me'); assert.equal(a.backPage(me, '/me'), '/me');
  a.rememberBusinessPath('/days/1000'); a.rememberBusinessPath('/events/r%3A1'); a.savePageScroll('/events/r%3A1', 400, '/me');
  assert.equal(a.backPage('/events/r%3A1', '/me'), '/days/1000');
  assert.equal(a.pageScroll('/events/r%3A1', '/'), 140); assert.equal(a.pageScroll('/events/r%3A1', '/me'), 400);
});
test('external, malformed and encoded traversal paths never replace the saved business return', () => {
  const a = fixture(); a.rememberBusinessPath('/me/backscreen');
  for (const path of ['//outside', 'https://outside', '/ask', '/actions/..', '/events/%2e%2e', '/events/%2f%2foutside', '/days/100?outside', '/me/%', '/events/r%5coutside']) {
    assert.equal(a.isBusinessPath(path), false, path); a.rememberBusinessPath(path); assert.equal(a.getReturnTo(), '/me/backscreen');
  }
  a.savePageScroll('/me', 480); a.savePageScroll('/actions', 120); assert.equal(a.pageScroll('/me'), 480); assert.equal(a.pageScroll('/events/r'), 0);
});
test('opening the same event again from its recording pushes a new visit; only explicit back pops', () => {
  const a = fixture(), event = '/events/r%3A1', recording = '/recordings/r';
  a.rememberBusinessPath('/'); a.rememberBusinessPath(event); a.rememberBusinessPath(recording); a.rememberBusinessPath(event);
  assert.equal(a.backPage(event, '/'), recording);
  a.rememberBusinessPath(recording, '/', true); assert.equal(a.backPage(recording, '/'), event);
  a.rememberBusinessPath(event, '/', true); assert.equal(a.backPage(event, '/'), '/');
  a.rememberBusinessPath('/', '/', true); assert.equal(a.getTabPath('/'), '/');
});
