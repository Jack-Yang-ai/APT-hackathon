import { useEffect, useId, useRef, type ReactNode } from 'react'

/** Shared chrome follows DS; the native dialog owns focus trapping and background inertness. */
export function Sheet({ open, title, busy = false, onClose, children, onSave, saveLabel = '保存', canSave = true }: {
  open: boolean; title: string; busy?: boolean; onClose: () => void; children: ReactNode
  onSave?: () => void; saveLabel?: string; canSave?: boolean
}) {
  const ref = useRef<HTMLDialogElement>(null), titleId = useId()
  useEffect(() => {
    const dialog = ref.current
    if (!dialog) return
    if (open && !dialog.open) dialog.showModal()
    if (!open && dialog.open) {
      dialog.close()
      // Saving may remove the nested sheet's trigger; restore focus into its still-open parent.
      const parents = document.querySelectorAll<HTMLDialogElement>('dialog[open]')
      const parent = parents[parents.length - 1]
      if (parent && !parent.contains(document.activeElement)) parent.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus()
    }
  }, [open])
  return <dialog ref={ref} className="apt-modal" aria-labelledby={titleId} onCancel={event => {
    event.preventDefault(); if (!busy) onClose()
  }} onClose={() => { if (open && !busy) onClose() }}>
    <header className="apt-modal-header">
      <button type="button" className="text-left" disabled={busy} onClick={onClose}>{onSave ? '取消' : '关闭'}</button>
      <h2 id={titleId}>{title}</h2>
      {onSave ? <button type="button" className="text-right font-semibold" disabled={busy || !canSave} onClick={onSave}>{busy ? '保存中…' : saveLabel}</button> : <span />}
    </header>
    <div className="apt-modal-body">{open ? children : null}</div>
  </dialog>
}

export function Intro({ title, children, trailing }: { title: string; children?: ReactNode; trailing?: ReactNode }) {
  return <header className="apt-intro flex items-start justify-between gap-2"><div className="min-w-0"><h1 className="apt-page-intro">{title}</h1>{children && <p>{children}</p>}</div>{trailing}</header>
}

export function Empty({ title, children }: { title: string; children?: ReactNode }) {
  return <div className="apt-empty"><h2>{title}</h2>{children && <p>{children}</p>}</div>
}

export function Info({ label, children }: { label: string; children: ReactNode }) {
  return <section><h2 className="apt-meta mb-1.5">{label}</h2><div className="whitespace-pre-wrap text-body">{children}</div></section>
}
