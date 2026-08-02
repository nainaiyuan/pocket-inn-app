#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
本地验证脚本（模拟版）——对照 lib/butler/butler_engine.dart 的 _detectSensitiveWords
逐行复刻判定链，验证综合公式 + 三档判定 + 白名单 + 求知减分。
注意：这是逻辑模拟（真代码依赖 flutter 包，本地无 Flutter SDK 跑不了），
公式与源码逐行对应，用于提前发现判定 bug；最终以编译后平板实测为准。
"""
import re

# ── 词表（对照 risk_filter_wordlist.dart 默认表，kind 默认 hard）──
WORDS = [
    # 测试词（用户说用完会删）
    ('爸爸', 'hard'), ('妈妈', 'hard'), ('老公', 'hard'), ('老婆', 'hard'),
    # 强敏感（亲密动作）
    ('亲', 'hard'), ('吻', 'hard'), ('抱', 'hard'), ('摸', 'hard'),
    ('舔', 'hard'), ('咬', 'hard'), ('揉', 'hard'), ('捏', 'hard'),
    ('含', 'hard'), ('吸', 'hard'), ('啃', 'hard'), ('插', 'hard'),
    ('塞', 'hard'), ('顶', 'hard'), ('脱', 'hard'), ('裸', 'hard'),
    ('湿', 'hard'), ('颤', 'hard'),
    # 弱敏感（身体部位）
    ('胸', 'soft'), ('腿', 'soft'), ('臀', 'soft'), ('腰', 'soft'),
    ('口', 'soft'), ('唇', 'soft'), ('舌', 'soft'), ('入', 'soft'),
    ('抽', 'soft'), ('送', 'soft'), ('进', 'soft'), ('流', 'soft'),
]
EXCEPTIONS = ['亲爱的', '进口', '亲人', '亲情']  # 白名单
PREF_BLOCK = 'block'

def detect(text, user_prefs=None, temp_allows=None, severe_words=()):
    """复刻 _detectSensitiveWords（跳过 IO，内存版）"""
    user_prefs = user_prefs or {}
    temp_allows = temp_allows or {}

    hits = []
    for sw in severe_words:  # 最高敏词（用户加在词表里并设为 severe）必然命中
        if sw in text:
            hits.append((sw, 'severe'))
    for w, kind in WORDS:
        if w in hits or w not in text:
            continue
        # 白名单覆盖 → 该词在此场景不敏感
        if any(e in text and w in e for e in EXCEPTIONS):
            continue
        hits.append((w, kind))
    if not hits:
        return ('放行', [], '无命中')

    # 临时豁免
    exempted = [w for w, k in hits if temp_allows.get(w) is not None]
    if exempted:
        hits = [h for h in hits if h[0] not in exempted]
        if not hits:
            return ('放行', exempted, f'临时豁免：{"/".join(exempted)}')

    # 用户已确认屏蔽 → 直接屏蔽
    confirmed = [w for w, k in hits if user_prefs.get(w) == PREF_BLOCK]
    if confirmed:
        return ('屏蔽', confirmed, '用户已确认屏蔽')

    # severe 最高敏 → 直接屏蔽
    severes = [w for w, k in hits if w in severe_words]
    if severes:
        return ('屏蔽', [w for w, _ in hits], 'severe 最高敏')

    # ── 综合公式 ──
    score = 0
    parts = []
    # ① 词基础分 hard+2 / soft+1
    ws = sum(2 if k == 'hard' else 1 for _, k in hits)
    score += ws
    parts.append(f'词{"/".join(w for w, _ in hits)}+{ws}')
    # ② 情感浓度分（复刻：fallback 平静 → +1；cv>=60 → +2；>=30 → +1）
    #    KeywordMoodAnalyzer 无"亲"等词 → dimensions 空 → fallback 平静80/放松50
    #    含 _keywordToMood 词的文本按真实计算，此处简化：命中硬词一律 fallback 兜底 +1
    conc = 1
    score += conc
    parts.append(f'浓度(兜底)+{conc}')
    # ③ 基线偏离（本地无基线数据 → 0）
    parts.append('基线0')
    # ④ 持续时间（首次触发 → 0）
    parts.append('持续0')
    # ⑤ 话题浓度：≥2 词 +1，≥3 词 +2
    topic = 2 if len(hits) >= 3 else (1 if len(hits) >= 2 else 0)
    score += topic
    parts.append(f'话题{len(hits)}词+{topic}')
    # ⑥ 求知减分 -1
    curiosity = _is_curiosity(text)
    if curiosity:
        score -= 1
        parts.append('求知-1')

    if score >= 5:
        return ('屏蔽', [w for w, _ in hits], f'{", ".join(parts)} = {score} ≥ 5')
    if score >= 3:
        return ('提醒', [w for w, _ in hits], f'{", ".join(parts)} = {score}，3≤score<5')
    return ('放行', [], f'{", ".join(parts)} = {score} < 3')

CURIOSITY_WORDS = ['什么是', '是什么', '啥是', '啥叫', '解释', '讲讲', '说说',
                   '介绍', '什么感觉', '什么体验', '科普', '含义', '告诉我',
                   '知道吗', '了解吗', '怎么写', '怎么读']

def _is_curiosity(text):
    """复刻 _isCuriosityIntent：求知词 + 问号/语气词；'是什么意思'/'啥意思' 无问号直判"""
    if '是什么意思' in text or '啥意思' in text:
        return True
    if any(k in text for k in CURIOSITY_WORDS):
        if any(q in text for q in '？?吗么呀啊呢'):
            return True
    return False

# ── 固定格式正则（对照 mask_engine.applyFormatMask）──
FORMAT_RULES = {
    '身份证号': re.compile(r'\b\d{17}[\dXx]\b', re.ASCII),
    '手机号': re.compile(r'\b1[3-9]\d{9}\b', re.ASCII),
    '邮箱': re.compile(r'\b[\w.+-]+@[\w-]+\.[\w.-]+\b', re.ASCII),
    '银行卡号': re.compile(r'\b\d{16,19}\b', re.ASCII),
}

def format_mask(text):
    matched = []
    for name, re_ in FORMAT_RULES.items():
        if re_.search(text):
            matched.append(name)
    return matched

# ── 运行 ──
print('═══ 判定链模拟验证（对照 butler_engine 源码）═══')
cases = [
    ('我想亲你', {}, {}, (), '提醒'),
    ('亲亲抱抱', {}, {}, (), '屏蔽'),
    ('接吻是什么感觉？', {}, {}, (), '放行（求知减分 2分）'),
    ('亲爱的，晚安', {}, {}, (), '放行（白名单覆盖"亲"）'),
    ('妈妈，我想你了', {}, {}, (), '提醒'),
    ('我想摸你的腿', {}, {}, (), '屏蔽（5分：摸硬+腿软+话题）'),
    ('做爱是什么感觉？', {}, {}, (), '放行'),
    ('做爱是什么感觉？', {}, {}, ('做爱',), '屏蔽'),
    ('亲是什么意思', {}, {}, (), '放行（硬词+求知=2分）'),
    ('我想亲你', {'亲': 'block'}, {}, (), '屏蔽'),
    ('我想亲你', {}, {'亲': '2099-01-01T00:00:00'}, (), '放行'),
]
ok = True
for text, prefs, temps, sev, expect in cases:
    verdict, words, detail = detect(text, prefs, temps, sev)
    exp_v = expect.split('（')[0]
    mark = '✅' if verdict == exp_v else '❌'
    if mark == '❌':
        ok = False
    print(f'{mark} "{text}" → {verdict} {words} | {detail} | 预期：{expect}')

print()
print('═══ 复述/跟念指令验证（butler_engine._isRepeatInstruction）═══')
REPEAT_WORDS = ['跟我念', '跟我读', '念一遍', '读一遍', '说一遍', '复述', '跟着说',
                '跟我喊', '喊一遍', '喊一声', '叫一声', '你念', '你喊', '你读',
                '跟我叫', '叫一遍', '念给我听']
def is_repeat(t):
    t = t.strip().lower()
    return any(w in t for w in REPEAT_WORDS)

repeat_cases = [
    ('跟我念:妈妈', True), ('跟我读：爸爸', True), ('你念一遍"妈妈"', True),
    ('复述一下这句话', True), ('喊一声老公', True), ('我想你了妈妈', False),
    ('妈妈在干嘛', False),
]
for t, expect in repeat_cases:
    got = is_repeat(t)
    mark = '✅' if got == expect else '❌'
    if mark == '❌':
        ok = False
    print(f'{mark} "{t}" → {"复述指令（绕过假面层）" if got else "正常"} | 预期：{"复述" if expect else "正常"}')

print()
print('═══ 固定格式正则验证（对照 mask_engine.applyFormatMask）═══')
fmt_cases = [
    ('我的身份证是110101199003071234，收一下', ['身份证号', '银行卡号']),  # 18位数字同时命中银行卡规则（真实行为，都挖空）
    ('电话 13812345678 联系我', ['手机号']),
    ('邮箱 test@example.com 发我', ['邮箱']),
    ('卡号 6222020200112233445 转账', ['银行卡号']),
    ('我想亲你', []),
    ('普通聊天没有敏感信息', []),
    ('17位数字12345678901234567', ['银行卡号']),  # 17位数字 → 银行卡（非身份证）
    ('18位纯数字123456789012345678', ['身份证号', '银行卡号']),  # 两规则都命中（都挖空，弹窗会列两个）
    ('11位手机号 12345678901', []),  # 非1[3-9]开头 → 不匹配
]
for text, expect in fmt_cases:
    got = format_mask(text)
    mark = '✅' if sorted(got) == sorted(expect) else '❌'
    if mark == '❌':
        ok = False
    print(f'{mark} "{text}" → {got} | 预期：{expect}')

print()
print('═══ 输入拦截 formatter 正则（对照 sensitive_input_formatter.dart）═══')
fmt2_cases = [
    ('110101199003071234', True), ('13812345678', True),
    ('test@example.com', True), ('6222020200112233445', True),
    ('我想亲你', False), ('你好呀', False), ('12345', False),
    ('12345678901234567', True),  # 17位数字 → 银行卡命中 → 输不进去
]
for text, expect in fmt2_cases:
    hit = any(r.search(text) for r in FORMAT_RULES.values())
    mark = '✅' if hit == expect else '❌'
    if mark == '❌':
        ok = False
    print(f'{mark} 输入"{text}" → {"拦截" if hit else "放行"} | 预期：{"拦截" if expect else "放行"}')

print()
print('全部通过 ✅' if ok else '有失败 ❌ 需检查')
