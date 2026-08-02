#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate three full-scale GalGame GamePackage JSON files with realistic
distractors, immersive dialogue, feedback scenes, and proper UUID v4."""
import json
import uuid

REVIEW_PLAN_ID = "8e812950-3311-40a7-93ab-636409df8cc2"
SNAPSHOT_VERSION = "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620"

# Knowledge point IDs (stable, shared across all three packages)
KP_TILLERING   = "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"  # 分蘖期管理
KP_GROWTH_CYCLE = "84f7d873-e573-4689-b18d-6f82c745d1bf"  # 基本生长周期
KP_JOINTING    = "f6a7b8c9-d0e1-4f2a-3b4c-5d6e7f8090a0"  # 拔节期与抽穗期
KP_MATURITY    = "c9d0e1f2-a3b4-4c5d-6e7f-8090a1b2c3d3"  # 成熟期判断

STANDARD_STEM = "根据所学内容，关于「{}」最准确的描述是？"
BASIC_STEM = "关于「{}」，以下哪个说法是正确的？"
ADVANCED_STEM = "在深入理解「{}」的基础上，以下哪个选项最符合实际？"


def uid():
    return str(uuid.uuid4())


def dialogue(speaker, text, emotion=None):
    d = {"speakerId": speaker, "text": text}
    if emotion:
        d["emotion"] = emotion
    return d


def nav_choice(scene_id, kp_id, text, next_scene):
    return {
        "choiceId": f"c-{scene_id}-1",
        "questionId": uid(),
        "text": text,
        "nextSceneId": next_scene,
        "scoreDelta": 0,
        "knowledgePointId": kp_id,
    }


def question_choice(scene_id, q_id, kp_id, text, correct, next_scene, idx=None):
    if correct:
        cid = f"c-{scene_id}-correct"
    else:
        cid = f"c-{scene_id}-d{idx}"
    c = {
        "choiceId": cid,
        "questionId": q_id,
        "text": text,
        "nextSceneId": next_scene,
        "scoreDelta": 1 if correct else 0,
        "knowledgePointId": kp_id,
        "answerKind": "CHOICE",
        "correct": correct,
    }
    return c


def binding(kp_id, purpose, q_id=None):
    b = {"knowledgePointId": kp_id, "purpose": purpose}
    if purpose == "QUESTION" and q_id:
        b["questionId"] = q_id
    else:
        b["questionId"] = None
    return b


def scene(scene_id, title, dialogues, choices, bindings):
    return {
        "sceneId": scene_id,
        "title": title,
        "dialogue": dialogues,
        "choices": choices,
        "knowledgeBindings": bindings,
    }


def make_qid():
    return uid()


# ============================================================
# Q&A bank: realistic, pedagogically meaningful distractors
# ============================================================

QA_TILLERING = {
    "kp": KP_TILLERING,
    "title": "水稻分蘖期管理",
    "stem": STANDARD_STEM.format("水稻分蘖期管理"),
    "correct": "协调群体数量与个体生长，通过水肥调控促进有效分蘖，控制无效分蘖",
    "distractors": [
        "分蘖期应深水灌溉以促进分蘖芽萌发，水深保持 10cm 以上",
        "分蘖期管理的核心是尽早追施大量氮肥，使分蘖数越多越好",
        "分蘖期不需要水分管理，保持自然降雨即可",
    ],
}

QA_JOINTING = {
    "kp": KP_JOINTING,
    "title": "水稻拔节期管理",
    "stem": STANDARD_STEM.format("水稻拔节期管理"),
    "correct": "拔节期需保持田间浅水层，注意防止倒伏，适当控制氮肥以防茎秆徒长",
    "distractors": [
        "拔节期应排水晒田至土壤开裂，促进根系向深层下扎",
        "拔节期主要管理目标是促进分蘖大量发生，增加有效穗数",
        "拔节期对水分和养分需求不大，可以减少灌溉和施肥",
    ],
}

QA_MATURITY = {
    "kp": KP_MATURITY,
    "title": "水稻成熟期判断标准",
    "stem": BASIC_STEM.format("水稻成熟期的判断标准"),
    "correct": "水稻成熟期分为乳熟期、蜡熟期和完熟期，完熟期籽粒含水量降至 20%~25%，是最佳收获期",
    "distractors": [
        "成熟期只需观察叶片是否全部变黄即可决定收获时间",
        "乳熟期籽粒充满乳浆时是最佳收获期，此时产量最高",
        "成熟期判断与籽粒含水量无关，主要看穗部颜色变化",
    ],
}


# ============================================================
# CAMPUS - STANDARD (8 scenes, 3 questions, 2 feedback scenes)
# ============================================================

def gen_campus():
    SP = "林学姐"
    pkg_id = uid()
    s = []

    # scene-001: Entry
    q_nav_1 = uid()
    s.append(scene("scene-001", "图书馆的自习时光", [
        dialogue(SP, "嘿，学弟！今天又是复习日呢。学姐已经占到图书馆老位置啦，窗边的那个，阳光正好。", "cheerful"),
        dialogue(SP, "今天我们要系统复习「水稻」的相关知识，从生长周期到田间管理，一共三道题。", "encouraging"),
        dialogue(SP, "放心，学姐会带你一步步走完的。每道题之前我都会先帮你梳理知识点，不用紧张。准备好了就开始吧！", "warm"),
    ], [
        nav_choice("scene-001", KP_TILLERING, "准备好了，开始吧！", "scene-002"),
    ], [
        binding(KP_TILLERING, "FEEDBACK", q_nav_1),
    ]))

    # scene-002: Explain - Growth Cycle
    q_nav_2 = uid()
    s.append(scene("scene-002", "知识点讲解：水稻基本生长周期", [
        dialogue(SP, "在正式做题之前，我们先回顾一下「水稻基本生长周期」，这可是后面所有题目的基础。", "thoughtful"),
        dialogue(SP, "水稻从播种到成熟，完整经历五个阶段：幼苗期、分蘖期、拔节期、抽穗期和成熟期。每个阶段都有不同的生理特征和管理重点。", "explaining"),
        dialogue(SP, "比如分蘖期关注群体数量，抽穗期关注水分供应。记住这个大框架，等下做题就不会一头雾水了。", "informative"),
    ], [
        nav_choice("scene-002", KP_GROWTH_CYCLE, "了解了，继续。", "scene-003"),
    ], [
        binding(KP_GROWTH_CYCLE, "EXPLAIN", q_nav_2),
    ]))

    # scene-003: Question 1 - Tillering
    q1 = make_qid()
    qa = QA_TILLERING
    choices = []
    choices.append(question_choice("scene-003", q1, qa["kp"], qa["correct"], True, "scene-004"))
    for i, dist in enumerate(qa["distractors"]):
        choices.append(question_choice("scene-003", q1, qa["kp"], dist, False, "scene-004", idx=i + 1))
    # Shuffle: correct at index 2
    choices = [choices[2], choices[0], choices[3], choices[1]]
    s.append(scene("scene-003", "复习题：水稻分蘖期管理", [
        dialogue(SP, "好，第一道题来了！这道题考的是分蘖期的管理。想想刚才讲过的五个阶段，分蘖期排在第二位，它的管理目标是什么呢？", "challenging"),
        dialogue(SP, qa["stem"], "questioning"),
    ], choices, [
        binding(qa["kp"], "QUESTION", q1),
    ]))

    # scene-004: Feedback
    q_nav_4 = uid()
    s.append(scene("scene-004", "中场小憩", [
        dialogue(SP, "做得不错！第一道题不管答对答错都没关系，重点是理解分蘖期管理的核心思路——「协调群体与个体」。", "warm"),
        dialogue(SP, "接下来学姐再带你回顾拔节期和抽穗期的知识，然后出第二道题。深呼吸，继续！", "encouraging"),
    ], [
        nav_choice("scene-004", KP_TILLERING, "好的，继续！", "scene-005"),
    ], [
        binding(KP_TILLERING, "FEEDBACK", q_nav_4),
    ]))

    # scene-005: Explain - Jointing & Heading
    q_nav_5 = uid()
    s.append(scene("scene-005", "知识点讲解：水稻拔节期与抽穗期", [
        dialogue(SP, "分蘖期之后就是拔节期和抽穗期了。这两个阶段对水分和养分的需求很高，是决定产量的关键期。", "thoughtful"),
        dialogue(SP, "拔节期是茎秆快速伸长的阶段，此时需要保持田间有浅水层，同时注意防止倒伏，适当控制氮肥，避免茎秆徒长而柔弱。", "explaining"),
        dialogue(SP, "抽穗期则是决定穗粒数的关键时期，需要保证充足的水分供应和适当的追肥。两个阶段共同决定了最终的产量构成。", "informative"),
    ], [
        nav_choice("scene-005", KP_JOINTING, "明白了，出题吧！", "scene-006"),
    ], [
        binding(KP_JOINTING, "EXPLAIN", q_nav_5),
    ]))

    # scene-006: Question 2 - Jointing
    q2 = make_qid()
    qa = QA_JOINTING
    choices = []
    choices.append(question_choice("scene-006", q2, qa["kp"], qa["correct"], True, "scene-007"))
    for i, dist in enumerate(qa["distractors"]):
        choices.append(question_choice("scene-006", q2, qa["kp"], dist, False, "scene-007", idx=i + 1))
    # Shuffle: correct at index 1
    choices = [choices[2], choices[0], choices[3], choices[1]]
    s.append(scene("scene-006", "复习题：水稻拔节期管理要点", [
        dialogue(SP, "第二道题来了！这次考的是拔节期的管理要点。关键词是「浅水层」「防倒伏」「控氮肥」，想想为什么。", "challenging"),
        dialogue(SP, qa["stem"], "questioning"),
    ], choices, [
        binding(qa["kp"], "QUESTION", q2),
    ]))

    # scene-007: Question 3 - Maturity
    q3 = make_qid()
    qa = QA_MATURITY
    choices = []
    choices.append(question_choice("scene-007", q3, qa["kp"], qa["correct"], True, "scene-008"))
    for i, dist in enumerate(qa["distractors"]):
        choices.append(question_choice("scene-007", q3, qa["kp"], dist, False, "scene-008", idx=i + 1))
    # Shuffle: correct at index 2
    choices = [choices[3], choices[0], choices[2], choices[1]]
    s.append(scene("scene-007", "最后一道题：水稻成熟期判断", [
        dialogue(SP, "还有最后一道题！这次考成熟期的判断标准。提示：成熟期不是只看叶子颜色那么简单哦。", "playful"),
        dialogue(SP, qa["stem"], "questioning"),
    ], choices, [
        binding(qa["kp"], "QUESTION", q3),
    ]))

    # scene-008: Ending
    s.append(scene("scene-008", "复习结束", [
        dialogue(SP, "太棒了！三道题全部完成，你对水稻生长周期和田间管理的理解又加深了不少呢。", "proud"),
        dialogue(SP, "本次复习涵盖分蘖期、拔节期和成熟期三个核心知识点。学姐会记住你的进度，下次根据薄弱环节出题。", "warm"),
        dialogue(SP, "好啦，去喝杯水休息一下吧，下次复习见！", "cheerful"),
    ], [], []))

    return {
        "schemaVersion": "1.0",
        "packageId": pkg_id,
        "generatorVersion": "gala-0.1.0",
        "reviewPlanId": REVIEW_PLAN_ID,
        "snapshotVersion": SNAPSHOT_VERSION,
        "entrySceneId": "scene-001",
        "scenes": s,
        "assets": [],
    }


# ============================================================
# FANTASY - ADVANCED (7 scenes, 3 questions, 1 feedback scene)
# ============================================================

def gen_fantasy():
    SP = "精灵导师艾莉娅"
    pkg_id = uid()
    s = []

    # scene-001: Entry
    q_nav_1 = uid()
    s.append(scene("scene-001", "魔法学院的试炼", [
        dialogue(SP, "勇敢的冒险者，欢迎踏入知识之塔。这里的每一块石砖都铭刻着自然法则的纹路，今天我们将一同解读大地生长的奥秘。", "mystical"),
        dialogue(SP, "知识之塔的试炼分为三重关卡，每一关都蕴含着水稻生长的智慧。唯有通过全部三关，你才能获得「丰收之印」。", "encouraging"),
        dialogue(SP, "今天我们要探索的主题是：水稻·生长周期。准备好了吗，冒险者？", "serious"),
    ], [
        nav_choice("scene-001", KP_TILLERING, "准备好了，开始吧！", "scene-002"),
    ], [
        binding(KP_TILLERING, "FEEDBACK", q_nav_1),
    ]))

    # scene-002: Explain - Growth Cycle
    q_nav_2 = uid()
    s.append(scene("scene-002", "第一重启示：水稻基本生长周期", [
        dialogue(SP, "在正式试炼之前，先让我为你揭示「水稻基本生长周期」的奥秘。这段知识将化作你的武器。", "thoughtful"),
        dialogue(SP, "水稻从播种到成熟的完整生长周期，包括幼苗期、分蘖期、拔节期、抽穗期和成熟期。这是大地的韵律，也是万物生长的基本法则。", "explaining"),
        dialogue(SP, "将这段周期铭刻于心，它将是你通过三重试炼的关键。", "informative"),
    ], [
        nav_choice("scene-002", KP_GROWTH_CYCLE, "了解了，继续。", "scene-003"),
    ], [
        binding(KP_GROWTH_CYCLE, "EXPLAIN", q_nav_2),
    ]))

    # scene-003: Question 1 - Tillering (ADVANCED: 3 choices)
    q1 = make_qid()
    qa = QA_TILLERING
    qa_stem = ADVANCED_STEM.format(qa["title"])
    choices = []
    choices.append(question_choice("scene-003", q1, qa["kp"], qa["correct"], True, "scene-004"))
    for i, dist in enumerate(qa["distractors"][:2]):
        choices.append(question_choice("scene-003", q1, qa["kp"], dist, False, "scene-004", idx=i + 1))
    # Shuffle: correct at index 1
    choices = [choices[2], choices[0], choices[1]]
    s.append(scene("scene-003", "试炼之一：水稻分蘖期管理", [
        dialogue(SP, "第一重试炼开始了。请回答这个问题——", "challenging"),
        dialogue(SP, qa_stem, "questioning"),
    ], choices, [
        binding(qa["kp"], "QUESTION", q1),
    ]))

    # scene-004: Explain + Feedback - Jointing
    q_nav_4 = uid()
    s.append(scene("scene-004", "第二重启示：水稻拔节期与抽穗期", [
        dialogue(SP, "你的智慧之火正在燃烧。第一重试炼已经通过，现在让我为你揭示下一层奥秘。", "thoughtful"),
        dialogue(SP, "分蘖期之后，水稻进入拔节期。此时茎秆如同世界树的枝干般拔地而起，需要大量的水分和养分支撑，但不可过度施氮，否则茎秆徒长而柔弱，容易倒伏。", "explaining"),
        dialogue(SP, "拔节期的关键在于：保持田间浅水层，防止倒伏，适当控制氮肥。随后进入抽穗期，需保证充足水分和追肥，以决定穗粒数。", "informative"),
    ], [
        nav_choice("scene-004", KP_JOINTING, "我已铭记于心，继续试炼。", "scene-005"),
    ], [
        binding(KP_JOINTING, "EXPLAIN", q_nav_4),
    ]))

    # scene-005: Question 2 - Jointing (ADVANCED: 3 choices)
    q2 = make_qid()
    qa = QA_JOINTING
    qa_stem = ADVANCED_STEM.format(qa["title"])
    choices = []
    choices.append(question_choice("scene-005", q2, qa["kp"], qa["correct"], True, "scene-006"))
    for i, dist in enumerate(qa["distractors"][:2]):
        choices.append(question_choice("scene-005", q2, qa["kp"], dist, False, "scene-006", idx=i + 1))
    # Shuffle: correct at index 0
    choices = [choices[0], choices[2], choices[1]]
    s.append(scene("scene-005", "试炼之二：水稻拔节期管理", [
        dialogue(SP, "第二重试炼降临，请听题——", "challenging"),
        dialogue(SP, qa_stem, "questioning"),
    ], choices, [
        binding(qa["kp"], "QUESTION", q2),
    ]))

    # scene-006: Question 3 - Maturity (ADVANCED: 3 choices)
    q3 = make_qid()
    qa = QA_MATURITY
    qa_stem = ADVANCED_STEM.format(qa["title"])
    choices = []
    choices.append(question_choice("scene-006", q3, qa["kp"], qa["correct"], True, "scene-007"))
    for i, dist in enumerate(qa["distractors"][:2]):
        choices.append(question_choice("scene-006", q3, qa["kp"], dist, False, "scene-007", idx=i + 1))
    # Shuffle: correct at index 2
    choices = [choices[1], choices[2], choices[0]]
    s.append(scene("scene-006", "试炼之三：水稻成熟期判断", [
        dialogue(SP, "最后一重试炼！这是对你整体理解的最终考验。", "challenging"),
        dialogue(SP, qa_stem, "questioning"),
    ], choices, [
        binding(qa["kp"], "QUESTION", q3),
    ]))

    # scene-007: Ending
    s.append(scene("scene-007", "试炼完成", [
        dialogue(SP, "你的智慧之光闪耀夺目，三重试炼圆满完成！「丰收之印」已铭刻于你的灵魂。", "proud"),
        dialogue(SP, "本次试炼涵盖分蘖期、拔节期和成熟期三个知识维度。你的成长已被知识之塔铭记。", "warm"),
        dialogue(SP, "知识之塔将记住你的试炼轨迹。下次到来时，试炼会根据你的薄弱之处重新排列。", "mystical"),
    ], [], []))

    return {
        "schemaVersion": "1.0",
        "packageId": pkg_id,
        "generatorVersion": "gala-0.1.0",
        "reviewPlanId": REVIEW_PLAN_ID,
        "snapshotVersion": SNAPSHOT_VERSION,
        "entrySceneId": "scene-001",
        "scenes": s,
        "assets": [],
    }


# ============================================================
# SCIENCE - BASIC (9 scenes, 3 questions, 2 feedback scenes)
# ============================================================

def gen_science():
    SP = "NEXUS"
    pkg_id = uid()
    s = []

    # scene-001: Entry
    q_nav_1 = uid()
    s.append(scene("scene-001", "空间站知识模块", [
        dialogue(SP, "研究员，欢迎接入 NEXUS 知识系统。今日学习模块已加载完毕，通信链路稳定。", "calm"),
        dialogue(SP, "今日的复习模块为：水稻·生长周期。该模块包含 3 个评估节点，将依次检测你对分蘖期、拔节期和成熟期的知识掌握度。", "informative"),
        dialogue(SP, "系统将在每个评估节点前提供知识摘要，确保你有足够的上下文进行作答。准备好了请确认。", "serious"),
    ], [
        nav_choice("scene-001", KP_TILLERING, "准备好了，开始吧！", "scene-002"),
    ], [
        binding(KP_TILLERING, "FEEDBACK", q_nav_1),
    ]))

    # scene-002: Explain A - Growth Cycle
    q_nav_2 = uid()
    s.append(scene("scene-002", "知识模块 A：水稻基本生长周期", [
        dialogue(SP, "在进入第一个评估节点之前，系统将输出「水稻基本生长周期」的知识摘要。", "thoughtful"),
        dialogue(SP, "水稻从播种到成熟的完整生长周期，包括幼苗期、分蘖期、拔节期、抽穗期和成熟期。每个阶段对应不同的生理特征和管理要求。", "explaining"),
        dialogue(SP, "该摘要将作为后续评估的知识基准。请确认已读取。", "informative"),
    ], [
        nav_choice("scene-002", KP_GROWTH_CYCLE, "了解了，继续。", "scene-003"),
    ], [
        binding(KP_GROWTH_CYCLE, "EXPLAIN", q_nav_2),
    ]))

    # scene-003: Question 1 - Tillering (BASIC: 4 choices)
    q1 = make_qid()
    qa = QA_TILLERING
    qa_stem = BASIC_STEM.format(qa["title"])
    choices = []
    choices.append(question_choice("scene-003", q1, qa["kp"], qa["correct"], True, "scene-004"))
    for i, dist in enumerate(qa["distractors"]):
        choices.append(question_choice("scene-003", q1, qa["kp"], dist, False, "scene-004", idx=i + 1))
    # Shuffle: correct at index 3
    choices = [choices[1], choices[2], choices[3], choices[0]]
    s.append(scene("scene-003", "评估节点 1：水稻分蘖期管理", [
        dialogue(SP, "系统已生成评估问题，请作答。", "challenging"),
        dialogue(SP, qa_stem, "questioning"),
    ], choices, [
        binding(qa["kp"], "QUESTION", q1),
    ]))

    # scene-004: Feedback
    q_nav_4 = uid()
    s.append(scene("scene-004", "评估节点 1 结果反馈", [
        dialogue(SP, "评估节点 1 已完成。作答数据已记录至知识图谱。", "calm"),
        dialogue(SP, "无论结果如何，系统建议你关注分蘖期管理中「群体与个体协调」这一核心概念。它贯穿了整个水稻田间管理思路。", "informative"),
    ], [
        nav_choice("scene-004", KP_TILLERING, "继续下一模块。", "scene-005"),
    ], [
        binding(KP_TILLERING, "FEEDBACK", q_nav_4),
    ]))

    # scene-005: Explain B - Jointing & Heading
    q_nav_5 = uid()
    s.append(scene("scene-005", "知识模块 B：水稻拔节期与抽穗期", [
        dialogue(SP, "系统将输出「水稻拔节期与抽穗期」的知识摘要。", "thoughtful"),
        dialogue(SP, "拔节期是茎秆快速生长的阶段，需要保持田间浅水层，注意防止倒伏，适当控制氮肥。过量施氮会导致茎秆徒长而柔弱。", "explaining"),
        dialogue(SP, "抽穗期是决定穗粒数的关键时期，需要保证充足的水分供应和适当的追肥。两个阶段共同决定了最终的产量构成。", "informative"),
    ], [
        nav_choice("scene-005", KP_JOINTING, "知识摘要已读取，继续。", "scene-006"),
    ], [
        binding(KP_JOINTING, "EXPLAIN", q_nav_5),
    ]))

    # scene-006: Question 2 - Jointing (BASIC: 4 choices)
    q2 = make_qid()
    qa = QA_JOINTING
    qa_stem = BASIC_STEM.format(qa["title"])
    choices = []
    choices.append(question_choice("scene-006", q2, qa["kp"], qa["correct"], True, "scene-007"))
    for i, dist in enumerate(qa["distractors"]):
        choices.append(question_choice("scene-006", q2, qa["kp"], dist, False, "scene-007", idx=i + 1))
    # Shuffle: correct at index 0
    choices = [choices[0], choices[2], choices[3], choices[1]]
    s.append(scene("scene-006", "评估节点 2：水稻拔节期管理要点", [
        dialogue(SP, "系统已生成评估问题，请作答。", "challenging"),
        dialogue(SP, qa_stem, "questioning"),
    ], choices, [
        binding(qa["kp"], "QUESTION", q2),
    ]))

    # scene-007: Explain C - Maturity
    q_nav_7 = uid()
    s.append(scene("scene-007", "知识模块 C：水稻成熟期", [
        dialogue(SP, "在最后一个评估节点前，系统将输出「水稻成熟期」的知识摘要。", "thoughtful"),
        dialogue(SP, "水稻成熟期分为乳熟期、蜡熟期和完熟期三个阶段。乳熟期籽粒充满乳状淀粉液，蜡熟期籽粒变硬呈蜡状，完熟期籽粒完全硬化。", "explaining"),
        dialogue(SP, "完熟期是最佳收获期，此时籽粒含水量降至 20%~25%，产量和品质均达到峰值。该指标是判断收获时机的权威依据。", "informative"),
    ], [
        nav_choice("scene-007", KP_MATURITY, "知识摘要已读取，继续。", "scene-008"),
    ], [
        binding(KP_MATURITY, "EXPLAIN", q_nav_7),
    ]))

    # scene-008: Question 3 - Maturity (BASIC: 4 choices)
    q3 = make_qid()
    qa = QA_MATURITY
    qa_stem = BASIC_STEM.format(qa["title"])
    choices = []
    choices.append(question_choice("scene-008", q3, qa["kp"], qa["correct"], True, "scene-009"))
    for i, dist in enumerate(qa["distractors"]):
        choices.append(question_choice("scene-008", q3, qa["kp"], dist, False, "scene-009", idx=i + 1))
    # Shuffle: correct at index 1
    choices = [choices[2], choices[0], choices[3], choices[1]]
    s.append(scene("scene-008", "评估节点 3：水稻成熟期判断标准", [
        dialogue(SP, "系统已生成最终评估问题，请作答。", "challenging"),
        dialogue(SP, qa_stem, "questioning"),
    ], choices, [
        binding(qa["kp"], "QUESTION", q3),
    ]))

    # scene-009: Ending
    s.append(scene("scene-009", "学习模块结束", [
        dialogue(SP, "所有评估节点已完成。学习数据已记录至知识图谱，你的知识掌握度持续提升中。", "proud"),
        dialogue(SP, "本次复习共完成 3 道题目，涵盖分蘖期管理、拔节期管理和成熟期判断三个评估节点。", "warm"),
        dialogue(SP, "系统将根据本次作答数据调整后续复习计划，优先覆盖掌握度较低的知识点。下次接入时将自动加载。", "calm"),
    ], [], []))

    return {
        "schemaVersion": "1.0",
        "packageId": pkg_id,
        "generatorVersion": "gala-0.1.0",
        "reviewPlanId": REVIEW_PLAN_ID,
        "snapshotVersion": SNAPSHOT_VERSION,
        "entrySceneId": "scene-001",
        "scenes": s,
        "assets": [],
    }


def main():
    import os
    out_dir = os.path.dirname(os.path.abspath(__file__))

    packages = [
        ("campus-standard-full.json", gen_campus()),
        ("fantasy-advanced-full.json", gen_fantasy()),
        ("science-basic-full.json", gen_science()),
    ]

    for filename, pkg in packages:
        path = os.path.join(out_dir, filename)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(pkg, f, ensure_ascii=False, indent=4)
        scene_count = len(pkg["scenes"])
        q_count = sum(1 for s in pkg["scenes"] for b in s["knowledgeBindings"] if b["purpose"] == "QUESTION")
        print(f"Generated: {filename} ({scene_count} scenes, {q_count} questions, packageId={pkg['packageId'][:8]}...)")


if __name__ == "__main__":
    main()
