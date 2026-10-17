import { MatterRow } from '../components/MatterRow'
import { useGrowth } from '@/shared/growth/store'
import { useGrowthProcessing } from '@/shared/growth/processing'
import { useGrowthRuntime } from '@/shared/growth/runtime'
import { usePageTitle } from '../layout/PageTitle'
export function RecordingsPage() {
  useGrowthRuntime();usePageTitle('录音与处理')
  const source=useGrowth(),processing=useGrowthProcessing()
  return <div className="page space-y-3"><p className="text-caption text-muted-foreground">原录音、恢复的材料与处理回执保留在这里。</p>
    {processing.error&&<p role="alert" className="text-caption text-danger">{processing.error}</p>}
    {source.matters.length?<ul className="apt-settings-group">{source.matters.map(matter=><MatterRow key={matter.id} matter={matter} segments={source.segments.filter(row=>row.matterId===matter.id)} jobs={processing.jobs.filter(row=>row.recordingId===matter.id)}/>)}</ul>:<p className="text-caption text-muted-foreground">还没有录音。</p>}
  </div>
}
