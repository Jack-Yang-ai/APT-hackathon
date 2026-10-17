/** Paths are the same approved vector assets as iOS AptGlyph; currentColor preserves state contrast. */
export function AptGlyph({ kind, size = 24 }: { kind: 'now' | 'me' | 'ask'; size?: number }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
    {kind === 'now' ? <path d="M3 12h2.5l2-5 3 10 3-13 3 15 2-7H21" /> : kind === 'me' ? <><circle cx="12" cy="7.5" r="3.5" /><path d="M5.5 21v-2a6.5 6.5 0 0 1 13 0v2" /></> : <><path d="M19 7a7.5 7.5 0 0 0-7-3.5C7 3.5 3.5 6.6 3.5 11c0 2.1.8 3.8 2.3 5.1L5 20.5l4.3-2a10.7 10.7 0 0 0 2.7.3c4.2 0 7.2-2.2 7.8-5.5M9 11.5c1 1.2 3.8 2 6 .7" /><circle cx="20" cy="10" r="1.2" fill="currentColor" stroke="none" /></>}
  </svg>
}
