import { Link } from 'react-router-dom'
import { ChevronRight } from 'lucide-react'
import { formatClock } from '@/shared/growth/format'
import type { UnderstoodEvent } from '@/shared/growth/processing-data'

/** Same 48pt time column, 12pt gap and 14pt vertical rhythm as HomeEventRow. */
export function EventRows({ events }: { events: UnderstoodEvent[] }) {
  return <ul>{events.map(event => <li key={event.id}>
    <Link to={`/events/${encodeURIComponent(event.id)}`} className="apt-event-row" aria-label={`${formatClock(event.startedAt)} – ${formatClock(event.endedAt)} ${event.title} ${event.summary}`}>
      <span className="apt-event-time"><time className="font-medium">{formatClock(event.startedAt)}</time><time className="text-muted-foreground">{formatClock(event.endedAt)}</time></span>
      <span className="min-w-0 flex-1"><span className="apt-event-title block">{event.title}</span><span className="apt-event-summary">{event.summary}</span></span>
      <ChevronRight className="mt-1 size-3 shrink-0 text-muted-foreground" aria-hidden />
    </Link>
  </li>)}</ul>
}
