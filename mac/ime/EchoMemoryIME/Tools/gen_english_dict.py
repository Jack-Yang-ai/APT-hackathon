#!/usr/bin/env python3
"""Build Data/echo_english.dict.yaml from rime-melt's melt_eng.dict.yaml.

    curl -fsSLO https://raw.githubusercontent.com/tumuyan/rime-melt/17fb3fa5e99a79daf8756b6daf78b65ecd1f3708/melt_eng.dict.yaml
    python3 Tools/gen_english_dict.py melt_eng.dict.yaml Data/echo_english.dict.yaml

Codes are the word's letters in lower case: that is all the pinyin speller lets
into the input. After changing this file, run `EchoMemoryIME --verify-typing`.
"""
import re, sys

# Basics missing from melt_eng plus non-pinyin tech/product names. Pinyin-based
# names (Taobao, Weibo, Baidu...) stay out so they never compete with 淘宝/微博/百度.
# word|code overrides the code; listed words come before melt_eng words with the same code.
SUPPLEMENT = """
am is are was were be been has had did does said got but yes yeah hey hi thanks bye okay true false
don't|dont can't|cant won't|wont isn't|isnt I'm|im that's|thats C++|cpp
email online offline demo debug sprint roadmap repo deploy backend frontend workflow dashboard
GitHub GitLab Git macOS iPadOS watchOS Xcode SwiftUI TypeScript npm Docker Kubernetes Vim VSCode
WeChat Figma YouTube TikTok LinkedIn OpenAI StepFun WithEcho Rime iCloud AirPods Safari Amazon
AWS PR SDK UX PM KPI OKR ROI MVP PRD PPT PDF JSON YAML HTTP HTTPS URL SQL LLM ASR TTS OCR GPU QQ
"""
# Their pinyin abbreviations are among the most typed: my 没有, by 不要, shy 使用.
# A lone "i" would turn iPhone into IPhone (the uppercase rule splits it after "i").
EXCLUDE = {"my", "by", "shy", "i"}

def entries(melt_path):
    words, seen = [], set()
    def add(word, code=None):
        code = code or re.sub("[^a-z]", "", word.lower())
        if not code or code in EXCLUDE or re.search(r"\d", word) or (word, code) in seen:
            return
        seen.add((word, code)); words.append((word, code))
    for token in SUPPLEMENT.split():
        word, _, code = token.partition("|"); add(word, code or None)
    body = False
    for line in open(melt_path, encoding="utf-8-sig"):
        line = line.rstrip("\n")
        if line.startswith("..."): body = True; continue
        if not body or not line or line.startswith("#"): continue
        word = line.split("\t")[0].strip()
        # Plain words only: drops key-combo fragments like Win+ / Ctrl+ and C++ coded as "c".
        if re.fullmatch(r"[A-Za-z][A-Za-z.\-']*", word): add(word)
    # Rime keeps file order for one code (sort: original). melt_eng deliberately lists
    # capitalised names (China, Swift, Steam) before the common word; keep that order.
    return words

HEADER = """# Rime dictionary
# encoding: utf-8
#
# Echo 中文模式下的英文单词候选，只做整词匹配（不补全、不造句、不学习）。
# 由 Tools/gen_english_dict.py 从 rime-melt 的 melt_eng.dict.yaml 生成，请勿手改。
# 来源：https://github.com/tumuyan/rime-melt （commit 17fb3fa）。rime-melt 仓库为
# Apache License 2.0（见 rime-melt-LICENSE.txt），其 README 说明词表原作者为 tanzi、未声明更多信息。
# 上游文件头原文：
#   Easy English Nano使用的英文主词典，主要构成为2016考研词汇大纲和六级单词，数据量6K条。
#   原作version 2017.03.31 by tanzi
#   修订version by tumuyan
#   2019.10	把原省略字符的字典，改为全文字典，并进行了一些扩展
#   2020.08	添加大写单词（放置在词典顶部），并对词条排序
# Echo 的改动：编码统一为去掉非字母后的全小写；去掉含数字、+ 的词条和与常用简拼冲突的
# my/by/shy；文件开头补充常用词和非拼音的科技/产品名。

---
name: echo_english
version: "2026.10.11"
sort: original
...

"""

if __name__ == "__main__":
    rows = entries(sys.argv[1])
    with open(sys.argv[2], "w", encoding="utf-8") as out:
        out.write(HEADER)
        for word, code in rows: out.write(f"{word}\t{code}\t100\n")
    print(len(rows), "entries")
