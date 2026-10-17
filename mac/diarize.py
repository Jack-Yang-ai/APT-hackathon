"""本地匿名说话人分离（diarization）（并入 growth-agent）。

复用 ModelScope/3D-Speaker 打包好的 CAM++ diarization 管线
（VAD → CAM++ embedding → 聚类），**不手搓切片+聚类**。只做匿名分人（说话人1/2/...），
不建声纹底库、不做 1:1 认人（用户判定预录同事不合适）。

⚠️ 重依赖（modelscope/funasr/torch）**全部函数内惰性 import**——`import ingest.meeting`
不装它们也能成功；run.py 在装好前自动退化为「未分人」，与上游一致。
装依赖：见 ingest/meeting/README 注释（torch + modelscope + funasr + 聚类后端）。

⚠️ 未验证：返回结构解析按官方文档写，**首次真实运行时必须核对 result 的实际结构**
（见 _parse_result 的兜底与断言）。
"""
from __future__ import annotations

from .align import SpeakerTurn

_MODEL = "iic/speech_campplus_speaker-diarization_common"


def diarize_turns(audio_path: str, *, oracle_num: int | None = None) -> list[SpeakerTurn]:
    """返回按时间排序的匿名说话人段。oracle_num 已知人数时可传以提升聚类质量。"""
    try:
        from modelscope.pipelines import pipeline
        from modelscope.utils.constant import Tasks
    except ImportError as e:
        raise RuntimeError(
            "未安装 modelscope/funasr。先装重依赖（torch/modelscope/funasr + 聚类后端），"
            "并确认 spike 已验证 ASR 时间戳粒度。"
        ) from e

    sd = pipeline(task=Tasks.speaker_diarization, model=_MODEL)
    kwargs = {"oracle_num": oracle_num} if oracle_num else {}
    result = sd(audio_path, **kwargs)
    return _parse_result(result)


def diarize_raw(audio_path: str, *, oracle_num: int | None = None) -> list[tuple[int, int, int]]:
    """分人的**原始产出**:`[(起毫秒, 止毫秒, 说话人号)]`,说话人号从 0 起。

    🔴 **不带任何显示格式**(M2-认6)。上面 `diarize_turns` 出的是 `说话人1` 给旧链路用,
    而送 Mac 兜底那条腿要的是**上游格式** `speaker_0` —— 两种格式,**一次解析**。
    """
    return [(t.start_ms, t.end_ms, int(t.speaker.removeprefix("说话人")) - 1)
            for t in diarize_turns(audio_path, oracle_num=oracle_num)]


def _parse_result(result) -> list[SpeakerTurn]:
    """文档约定 result['text'] 为 [[start_sec, end_sec, spk_id], ...]（秒）。
    首次运行核对：若结构不符，这里会断言失败，把真实 result 打出来再改。
    """
    raw = result.get("text") if isinstance(result, dict) else result
    assert raw is not None, f"diarization 返回结构异常，请打印核对: {result!r}"
    turns: list[SpeakerTurn] = []
    for item in raw:
        start_sec, end_sec, spk = item[0], item[1], item[2]
        turns.append(SpeakerTurn(
            start_ms=int(float(start_sec) * 1000),
            end_ms=int(float(end_sec) * 1000),
            speaker=f"说话人{int(spk) + 1}",
        ))
    turns.sort(key=lambda t: t.start_ms)
    return turns
