#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generate 3 complete narrative-enhanced game packages (CAMPUS/FANTASY/SCIENCE).

Each package follows the same PlanGraph (rice growth cycle + tillering management)
but wraps the knowledge in a completely different story skin.

Output: 3 JSON files in mocks/ directory, validated against schema + validator rules.
"""

import json
import uuid
import hashlib
import os

# ============================================================================
# Fixed IDs (must match NarrativeTestData.cs)
# ============================================================================
REVIEW_PLAN_ID = "8e812950-3311-40a7-93ab-636409df8cc2"
SNAPSHOT_VERSION = "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620"
PREREQUISITE_ID = "84f7d873-e573-4689-b18d-6f82c745d1bf"
TARGET_ID = "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"
GENERATOR_VERSION = "gala-0.1.0"

# PlanNode data (must match NarrativeTestData.cs)
PREREQUISITE_TITLE = "\u6c34\u7a3b\u57fa\u672c\u751f\u957f\u5468\u671f"  # 水稻基本生长周期
PREREQUISITE_SUMMARY = "\u6c34\u7a3b\u4ece\u64ad\u79cd\u5230\u6210\u719f\u4f1a\u7ecf\u5386\u5e7c\u82d7\u671f\u3001\u5206\u8618\u671f\u3001\u62d4\u8282\u671f\u3001\u62bd\u7a57\u671f\u548c\u6210\u719f\u671f\u3002"  # 水稻从播种到成熟会经历幼苗期、分蘖期、拔节期、抽穗期和成熟期。
TARGET_TITLE = "\u6c34\u7a3b\u5206\u8618\u671f\u7ba1\u7406"  # 水稻分蘖期管理
TARGET_SUMMARY = "\u6c34\u7a3b\u5206\u8618\u671f\u6700\u5173\u952e\u7684\u7ba1\u7406\u76ee\u6807\u662f\u534f\u8c03\u7fa4\u4f53\u6570\u91cf\u4e0e\u4e2a\u4f53\u751f\u957f\uff0c\u901a\u8fc7\u6c34\u80a5\u8c03\u63a7\u4fc3\u8fdb\u6709\u6548\u5206\u8618\u3002"  # 水稻分蘖期最关键的管理目标是协调群体数量与个体生长，通过水肥调控促进有效分蘖。

# Grounding quotes (must be exact substrings of title or summary)
PREREQUISITE_GROUNDING = "\u5e7c\u82d7\u671f"  # 幼苗期 (from summary)
TARGET_GROUNDING = "\u534f\u8c03\u7fa4\u4f53\u6570\u91cf\u4e0e\u4e2a\u4f53\u751f\u957f"  # 协调群体数量与个体生长 (from summary)

# Distractor texts (from ExtractDistractorFromNode logic)
DISTRACTOR_1 = "\u62d4\u8282\u671f\u3001\u62bd\u7a57\u671f\u548c\u6210\u719f\u671f\u662f\u540e\u7eed\u9636\u6bb5\uff0c\u4e0e\u5206\u8618\u671f\u7ba1\u7406\u5173\u7cfb\u4e0d\u5927"  # 拔节期、抽穗期和成熟期是后续阶段，与分蘖期管理关系不大
DISTRACTOR_2 = "\u8be5\u7ba1\u7406\u65b9\u6cd5\u4ec5\u9002\u7528\u4e8e\u7406\u8bba\u8003\u8bd5\uff0c\u5b9e\u9645\u751f\u4ea7\u4e2d\u65e0\u53c2\u8003\u4ef7\u503c"  # 该管理方法仅适用于理论考试，实际生产中无参考价值
DISTRACTOR_3 = "\u9700\u8981\u7ed3\u5408\u5177\u4f53\u5730\u533a\u6c14\u5019\u6761\u4ef6\u624d\u80fd\u5224\u65ad\u5176\u9002\u7528\u6027"  # 需要结合具体地区气候条件才能判断其适用性

# Navigation questionIds (deterministic, using same algorithm as GameGenerator)
QUESTION_NAMESPACE = uuid.UUID("a3f5c1e2-7b8d-4e6f-9a0b-1c2d3e4f5a6b")

def deterministic_guid(point_id_str: str, seed: int) -> str:
    """Generate deterministic UUID v4 from pointId + seed."""
    point_id = uuid.UUID(point_id_str)
    ns_bytes = QUESTION_NAMESPACE.bytes
    pid_bytes = point_id.bytes
    seed_bytes = seed.to_bytes(8, 'little')
    combined = ns_bytes + pid_bytes + seed_bytes
    digest = hashlib.sha256(combined).digest()
    b = bytearray(digest[:16])
    b[6] = (b[6] & 0x0F) | 0x40
    b[8] = (b[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(b)))

def navigation_guid(scene_id: str) -> str:
    """Generate navigation questionId for non-scoring scenes."""
    name_bytes = ("nav:" + scene_id).encode('utf-8')
    ns_bytes = QUESTION_NAMESPACE.bytes
    combined = ns_bytes + name_bytes
    digest = hashlib.sha256(combined).digest()
    b = bytearray(digest[:16])
    b[6] = (b[6] & 0x0F) | 0x40
    b[8] = (b[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(b)))

SEED = 42
QUESTION_ID = deterministic_guid(TARGET_ID, SEED)
NAV_SCENE_001 = navigation_guid("scene-001")
NAV_SCENE_002 = navigation_guid("scene-002")
NAV_SCENE_004 = navigation_guid("scene-004")

# ============================================================================
# Story Templates
# ============================================================================

def build_campus_package() -> dict:
    """CAMPUS style: greenhouse project deadline, two students with conflicting priorities."""
    pkg_id = str(uuid.uuid4())
    return {
        "schemaVersion": "1.0",
        "packageId": pkg_id,
        "generatorVersion": GENERATOR_VERSION,
        "reviewPlanId": REVIEW_PLAN_ID,
        "snapshotVersion": SNAPSHOT_VERSION,
        "entrySceneId": "scene-001",
        "scenes": [
            {
                "sceneId": "scene-001",
                "title": "\u96e8\u540e\u7684\u683c\u5bb4\u8bb0\u5f55\u672c",  # 雨后的格棚记录本
                "dialogue": [
                    {
                        "speakerId": "\u6797\u6f88",  # 林澈
                        "text": "\u6628\u665a\u7684\u66b4\u96e8\u6d47\u706d\u4e86\u683c\u5bb4\u7684\u81ea\u52a8\u704c\u6e89\u7cfb\u7edf\uff0c\u5468\u5d50\u8bf4\u4ed6\u4eca\u5929\u4e0b\u5348\u5c31\u80fd\u4fee\u597d\u3002\u4f46\u8fd9\u4efd\u89c2\u6d4b\u8bb0\u5f55\u2026\u2026\u5c11\u4e86\u4e00\u6574\u9875\u3002",  # 昨晚的暴雨浇灭了格棚的自动灌溉系统，周岚说他今天下午就能修好。但这份观测记录……少了一整页。
                        "emotion": "worried"
                    },
                    {
                        "speakerId": "\u5468\u5d50",  # 周岚
                        "text": "\u7ba1\u7ebf\u5230\u4e86\u4e0b\u5348\u4e09\u70b9\u624d\u80fd\u9001\u7535\uff0c\u6c34\u9053\u4e5f\u8fd8\u6ca1\u5b8c\u5168\u901a\u3002\u4f60\u5148\u628a\u73b0\u6709\u7684\u751f\u957f\u9636\u6bb5\u8bb0\u5f55\u6392\u987a\uff0c\u6211\u53bb\u770b\u770b\u6709\u6ca1\u6709\u5907\u4efd\u3002",  # 管线到了下午三点才能送电，水道也还没完全通。你先把现有的生长阶段记录排顺，我去看看有没有备份。
                        "emotion": "rushed"
                    },
                    {
                        "speakerId": "\u4f60",  # 你
                        "text": "\u6c34\u7a3b\u4ece\u64ad\u79cd\u5230\u6210\u719f\u4f1a\u7ecf\u5386\u5e7c\u82d7\u671f\u3001\u5206\u8618\u671f\u3001\u62d4\u8282\u671f\u3001\u62bd\u7a57\u671f\u548c\u6210\u719f\u671f\u3002\u5c11\u7684\u90a3\u9875\u8bb0\u7684\u5c31\u662f\u5206\u8618\u671f\u7684\u6570\u636e\u3002",  # 水稻从播种到成熟会经历幼苗期、分蘖期、拔节期、抽穗期和成熟期。少的那页记的就是分蘖期的数据。
                        "emotion": "focused"
                    }
                ],
                "choices": [
                    {
                        "choiceId": "c-scene-001-1",
                        "questionId": NAV_SCENE_001,
                        "text": "\u5148\u628a\u751f\u957f\u9636\u6bb5\u987a\u5e8f\u8fd8\u539f\uff0c\u518d\u53bb\u627e\u7f3a\u5931\u7684\u6570\u636e",  # 先把生长阶段顺序还原，再去找缺失的数据
                        "nextSceneId": "scene-002",
                        "scoreDelta": 0,
                        "knowledgePointId": TARGET_ID
                    }
                ],
                "knowledgeBindings": [
                    {
                        "knowledgePointId": TARGET_ID,
                        "questionId": NAV_SCENE_001,
                        "purpose": "FEEDBACK"
                    }
                ]
            },
            {
                "sceneId": "scene-002",
                "title": "\u88ab\u6253\u4e71\u7684\u751f\u957f\u65e5\u5fd7",  # 被打乱的生长日志
                "dialogue": [
                    {
                        "speakerId": "\u6797\u6f88",
                        "text": "\u6211\u628a\u5468\u5d50\u684c\u4e0a\u7684\u65e5\u5fd7\u62ff\u6765\u4e86\u3002\u5e7c\u82d7\u671f\u7684\u8bb0\u5f55\u5728\uff0c\u62d4\u8282\u671f\u4e4b\u540e\u7684\u4e5f\u5728\uff0c\u4f46\u4e2d\u95f4\u8fd9\u6bb5\u65ad\u4e86\u3002",  # 我把周岚桌上的日志拿来了。幼苗期的记录在，拔节期之后的也在，但中间这段断了。
                        "emotion": "thoughtful"
                    },
                    {
                        "speakerId": "\u4f60",
                        "text": "\u5e7c\u82d7\u671f\u4e4b\u540e\u5c31\u662f\u5206\u8618\u671f\uff0c\u8fd9\u6bb5\u6b63\u662f\u65e5\u5fd7\u7684\u65ad\u53e3\u3002\u5982\u679c\u987a\u5e8f\u9519\u4e86\uff0c\u540e\u9762\u7684\u5224\u65ad\u90fd\u4f1a\u5931\u53bb\u4f9d\u636e\u3002",  # 幼苗期之后就是分蘖期，这段正是日志的断口。如果顺序错了，后面的判断都会失去依据。
                        "emotion": "calm"
                    },
                    {
                        "speakerId": "\u5468\u5d50",
                        "text": "\u5907\u4efd\u627e\u5230\u4e86\uff0c\u4f46\u53ea\u6709\u534a\u9875\uff0c\u4e0a\u9762\u5199\u7684\u662f\u5206\u8618\u671f\u7684\u7ba1\u7406\u8981\u70b9\u3002\u6c34\u9053\u4e00\u901a\u5c31\u5f97\u8c03\u704c\u6e89\uff0c\u4f60\u5148\u770b\u770b\u8fd9\u4e9b\u8981\u70b9\u5bf9\u4e0d\u5bf9\u3002",  # 备份找到了，但只有半页，上面写的是分蘖期的管理要点。水道一通就得调灌溉，你先看看这些要点对不对。
                        "emotion": "hurried"
                    }
                ],
                "choices": [
                    {
                        "choiceId": "c-scene-002-1",
                        "questionId": NAV_SCENE_002,
                        "text": "\u7528\u751f\u957f\u9636\u6bb5\u987a\u5e8f\u5b9a\u4f4d\u65e5\u5fd7\u7f3a\u9875\uff0c\u518d\u6838\u5bf9\u7ba1\u7406\u8981\u70b9",  # 用生长阶段顺序定位日志缺页，再核对管理要点
                        "nextSceneId": "scene-003",
                        "scoreDelta": 0,
                        "knowledgePointId": PREREQUISITE_ID
                    }
                ],
                "knowledgeBindings": [
                    {
                        "knowledgePointId": PREREQUISITE_ID,
                        "questionId": NAV_SCENE_002,
                        "purpose": "EXPLAIN"
                    }
                ]
            },
            {
                "sceneId": "scene-003",
                "title": "\u5341\u5206\u949f\u7684\u53d6\u820d",  # 十分钟的取舍
                "dialogue": [
                    {
                        "speakerId": "\u5468\u5d50",
                        "text": "\u6c34\u9053\u901a\u4e86\uff01\u4f46\u6c34\u538b\u53ea\u591f\u7ef4\u6301\u5341\u5206\u949f\uff0c\u4e4b\u540e\u8fd8\u8981\u5207\u56de\u53bb\u4fee\u5176\u4ed6\u7ba1\u7ebf\u3002\u704c\u6e89\u91cf\u53ea\u80fd\u8c03\u4e00\u6b21\uff0c\u4f60\u6253\u7b97\u600e\u4e48\u7528\uff1f",  # 水道通了！但水压只够维持十分钟，之后还要切回去修其他管线。灌溉量只能调一次，你打算怎么用？
                        "emotion": "tense"
                    },
                    {
                        "speakerId": "\u6797\u6f88",
                        "text": "\u5982\u679c\u53ea\u704c\u6c34\u4e0d\u7ba1\u80a5\uff0c\u5206\u8618\u4f1a\u5f92\u957f\u4f46\u6839\u7cfb\u8d70\u6d45\u3002\u5982\u679c\u53ea\u65bd\u80a5\u4e0d\u704c\u6c34\uff0c\u80a5\u6599\u6839\u672c\u5316\u4e0d\u5f00\u3002\u4f60\u5f97\u544a\u8bc9\u6211\u4eec\u8fd9\u5341\u5206\u949f\u7684\u4f18\u5148\u7ea7\u3002",  # 如果只灌水不管肥，分蘖会徒长但根系走浅。如果只施肥不灌水，肥料根本化不开。你得告诉我们这十分钟的优先级。
                        "emotion": "pressured"
                    },
                    {
                        "speakerId": "\u4f60",
                        "text": "\u5206\u8618\u671f\u7684\u7ba1\u7406\u4e0d\u80fd\u53ea\u770b\u4e00\u4e2a\u65b9\u5411\u3002\u5982\u679c\u53ea\u987e\u7fa4\u4f53\u6570\u91cf\uff0c\u4e2a\u4f53\u957f\u4e0d\u58ee\uff1b\u5982\u679c\u53ea\u987e\u4e2a\u4f53\uff0c\u7fa4\u4f53\u53c8\u6563\u4e86\u3002\u6c34\u548c\u80a5\u5f97\u540c\u65f6\u8d77\u4f5c\u7528\u3002",  # 分蘖期的管理不能只看一个方向。如果只顾群体数量，个体长不壮；如果只顾个体，群体又散了。水和肥得同时起作用。
                        "emotion": "decisive"
                    }
                ],
                "choices": [
                    {
                        "choiceId": "c-scene-003-correct",
                        "questionId": QUESTION_ID,
                        "text": "\u534f\u8c03\u7fa4\u4f53\u6570\u91cf\u4e0e\u4e2a\u4f53\u751f\u957f\uff0c\u540c\u65f6\u8c03\u6574\u6c34\u80a5\u4fc3\u8fdb\u6709\u6548\u5206\u8618",  # 协调群体数量与个体生长，同时调整水肥促进有效分蘖
                        "nextSceneId": "scene-004",
                        "scoreDelta": 1,
                        "answerKind": "CHOICE",
                        "correct": True,
                        "knowledgePointId": TARGET_ID
                    },
                    {
                        "choiceId": "c-scene-003-d1",
                        "questionId": QUESTION_ID,
                        "text": DISTRACTOR_1,
                        "nextSceneId": "scene-004",
                        "scoreDelta": 0,
                        "answerKind": "CHOICE",
                        "correct": False,
                        "knowledgePointId": TARGET_ID
                    },
                    {
                        "choiceId": "c-scene-003-d2",
                        "questionId": QUESTION_ID,
                        "text": DISTRACTOR_2,
                        "nextSceneId": "scene-004",
                        "scoreDelta": 0,
                        "answerKind": "CHOICE",
                        "correct": False,
                        "knowledgePointId": TARGET_ID
                    },
                    {
                        "choiceId": "c-scene-003-d3",
                        "questionId": QUESTION_ID,
                        "text": DISTRACTOR_3,
                        "nextSceneId": "scene-004",
                        "scoreDelta": 0,
                        "answerKind": "CHOICE",
                        "correct": False,
                        "knowledgePointId": TARGET_ID
                    }
                ],
                "knowledgeBindings": [
                    {
                        "knowledgePointId": TARGET_ID,
                        "questionId": QUESTION_ID,
                        "purpose": "QUESTION"
                    }
                ]
            },
            {
                "sceneId": "scene-004",
                "title": "\u706f\u4eae\u8d77\u6765\u4ee5\u540e",  # 灯亮起来以后
                "dialogue": [
                    {
                        "speakerId": "\u5468\u5d50",
                        "text": "\u7ba1\u7ebf\u5168\u901a\u4e86\uff0c\u683c\u5bb4\u7684\u706f\u4e5f\u4eae\u4e86\u3002\u5341\u5206\u949f\u7684\u704c\u6e89\u8d77\u5230\u4e86\u4f5c\u7528\uff0c\u5206\u8618\u7684\u957f\u52bf\u548c\u6839\u7cfb\u90fd\u7b3c\u4f4f\u4e86\u3002",  # 管线全通了，格棚的灯也亮了。十分钟的灌溉起到了作用，分蘖的长势和根系都笼住了。
                        "emotion": "relieved"
                    },
                    {
                        "speakerId": "\u6797\u6f88",
                        "text": "\u7f3a\u5931\u7684\u90a3\u9875\u8bb0\u5f55\u6211\u5728\u5907\u4efd\u91cc\u627e\u5230\u4e86\uff0c\u4f60\u7684\u751f\u957f\u9636\u6bb5\u8fd8\u539f\u5e2e\u4e86\u5927\u5fd9\u3002\u8fd9\u6b21\u4e0d\u662f\u80cc\u4e00\u53e5\u8bdd\uff0c\u800c\u662f\u771f\u7684\u89e3\u51b3\u4e86\u95ee\u9898\u3002",  # 缺失的那页记录我在备份里找到了，你的生长阶段还原帮了大忙。这次不是背一句话，而是真的解决了问题。
                        "emotion": "grateful"
                    }
                ],
                "choices": [],
                "knowledgeBindings": []
            }
        ],
        "assets": [
            {"assetId": "asset-001", "type": "BACKGROUND", "uri": "assets/campus/bg/campus_library_day.webp"},
            {"assetId": "asset-002", "type": "BACKGROUND", "uri": "assets/campus/bg/campus_library_evening.webp"},
            {"assetId": "asset-003", "type": "BACKGROUND", "uri": "assets/campus/bg/campus_courtyard.webp"},
            {"assetId": "asset-004", "type": "CHARACTER", "uri": "assets/campus/char/char_senior_linn_neutral.webp"},
            {"assetId": "asset-005", "type": "CHARACTER", "uri": "assets/campus/char/char_senior_linn_smile.webp"},
            {"assetId": "asset-006", "type": "CHARACTER", "uri": "assets/campus/char/char_senior_linn_thinking.webp"},
            {"assetId": "asset-007", "type": "AUDIO", "uri": "assets/campus/audio/bgm_campus_calm.ogg"},
            {"assetId": "asset-008", "type": "AUDIO", "uri": "assets/campus/audio/sfx_page_flip.ogg"},
            {"assetId": "asset-009", "type": "AUDIO", "uri": "assets/campus/audio/sfx_chime_correct.ogg"}
        ]
    }


def build_fantasy_package() -> dict:
    """FANTASY style: valley community facing crop blight, two advisors disagree."""
    pkg_id = str(uuid.uuid4())
    return {
        "schemaVersion": "1.0",
        "packageId": pkg_id,
        "generatorVersion": GENERATOR_VERSION,
        "reviewPlanId": REVIEW_PLAN_ID,
        "snapshotVersion": SNAPSHOT_VERSION,
        "entrySceneId": "scene-001",
        "scenes": [
            {
                "sceneId": "scene-001",
                "title": "\u8c37\u5e95\u7684\u7a7a\u6863\u6848",  # 谷底的空档案案
                "dialogue": [
                    {
                        "speakerId": "\u827e\u9ece",  # 艾黎
                        "text": "\u4e0a\u6e21\u6865\u7684\u5b88\u62a4\u8005\u8bf4\uff0c\u8c37\u5e95\u7684\u7530\u5730\u6709\u4e00\u5757\u4e0d\u660e\u7684\u67af\u840e\u3002\u6211\u53bb\u67e5\u8fc7\uff0c\u571f\u91cc\u6ca1\u6709\u6bd2\uff0c\u4f46\u8c37\u7269\u6863\u6848\u91cc\u7f3a\u4e86\u4e00\u6bb5\u8bb0\u8f7d\u3002",  # 上渡桥的守护者说，谷底的田地有一块不明的枯萎。我去查过，土里没有毒，但谷物档案案里缺了一段记载。
                        "emotion": "concerned"
                    },
                    {
                        "speakerId": "\u6d1b\u6069",  # 洛恩
                        "text": "\u6863\u6848\u662f\u6211\u4eec\u7684\u547d\u6839\u5b50\u3002\u4f60\u8bf4\u7f3a\u4e86\u4e00\u6bb5\uff0c\u662f\u54ea\u4e00\u6bb5\uff1f\u522b\u544a\u8bc9\u6211\u662f\u71c3\u70e7\u5b63\u7684\u90a3\u6bb5\uff0c\u90a3\u6bb5\u4ece\u6765\u4e0d\u4f1a\u51fa\u95ee\u9898\u3002",  # 档案是我们的命根子。你说缺了一段，是哪一段？别告诉我是燃烧季的那段，那段从不会有问题。
                        "emotion": "guarded"
                    },
                    {
                        "speakerId": "\u4f60",
                        "text": "\u8c37\u7269\u4ece\u64ad\u79cd\u5230\u6210\u719f\u4f1a\u7ecf\u5386\u5e7c\u82d7\u671f\u3001\u5206\u8618\u671f\u3001\u62d4\u8282\u671f\u3001\u62bd\u7a57\u671f\u548c\u6210\u719f\u671f\u3002\u7f3a\u7684\u5c31\u662f\u5206\u8618\u671f\u7684\u8bb0\u8f7d\uff0c\u6070\u597d\u662f\u67af\u840e\u51fa\u73b0\u7684\u65f6\u671f\u3002",  # 谷物从播种到成熟会经历幼苗期、分蘖期、拔节期、抽穗期和成熟期。缺的就是分蘖期的记载，恰好是枯萎出现的时期。
                        "emotion": "focused"
                    }
                ],
                "choices": [
                    {
                        "choiceId": "c-scene-001-1",
                        "questionId": NAV_SCENE_001,
                        "text": "\u5148\u628a\u751f\u957f\u9636\u6bb5\u987a\u5e8f\u62fc\u5b8c\uff0c\u518d\u53bb\u73b0\u573a\u770b\u67af\u840e",  # 先把生长阶段顺序拼完，再去现场看枯萎
                        "nextSceneId": "scene-002",
                        "scoreDelta": 0,
                        "knowledgePointId": TARGET_ID
                    }
                ],
                "knowledgeBindings": [
                    {
                        "knowledgePointId": TARGET_ID,
                        "questionId": NAV_SCENE_001,
                        "purpose": "FEEDBACK"
                    }
                ]
            },
            {
                "sceneId": "scene-002",
                "title": "\u6298\u53e0\u7684\u7f8a\u76ae\u7eb8",  # 折叠的羊皮纸
                "dialogue": [
                    {
                        "speakerId": "\u827e\u9ece",
                        "text": "\u6211\u5728\u6863\u6848\u67dc\u7684\u5939\u5c42\u91cc\u627e\u5230\u4e86\u4e00\u5f20\u6298\u53e0\u7684\u7f8a\u76ae\u7eb8\u3002\u4e0a\u9762\u7684\u5b57\u8ff9\u88ab\u6c34\u6d47\u8fc7\uff0c\u4f46\u80fd\u8fa8\u8ba4\u51fa\u300c\u5206\u8618\u300d\u4e24\u4e2a\u5b57\u3002",  # 我在档案柜的夹层里找到了一张折叠的羊皮纸。上面的字迹被水浇过，但能辨认出「分蘖」两个字。
                        "emotion": "hopeful"
                    },
                    {
                        "speakerId": "\u4f60",
                        "text": "\u5e7c\u82d7\u671f\u4e4b\u540e\u5c31\u662f\u5206\u8618\u671f\uff0c\u8fd9\u6bb5\u662f\u8bb0\u8f7d\u7684\u65ad\u53e3\u3002\u5982\u679c\u987a\u5e8f\u62fc\u9519\uff0c\u540e\u9762\u7684\u5224\u65ad\u5168\u4f1a\u8d70\u504f\u3002",  # 幼苗期之后就是分蘖期，这段是记载的断口。如果顺序拼错，后面的判断全会走偏。
                        "emotion": "calm"
                    },
                    {
                        "speakerId": "\u6d1b\u6069",
                        "text": "\u7f8a\u76ae\u7eb8\u7684\u80cc\u9762\u8fd8\u6709\u5b57\u3002\u5199\u7684\u662f\u5206\u8618\u671f\u7684\u7ba1\u7406\u8981\u70b9\uff0c\u4f46\u6709\u4e00\u53e5\u88ab\u6ed1\u7b14\u6d82\u6389\u4e86\u3002\u4f60\u4eec\u770b\u770b\u80fd\u4e0d\u80fd\u5165\u8fd9\u4e2a\u7a7a\u7f3a\u3002",  # 羊皮纸的背面还有字。写的是分蘖期的管理要点，但有一句被滑笔涂掉了。你们看看能不能入这个空缺。
                        "emotion": "curious"
                    }
                ],
                "choices": [
                    {
                        "choiceId": "c-scene-002-1",
                        "questionId": NAV_SCENE_002,
                        "text": "\u7528\u751f\u957f\u9636\u6bb5\u987a\u5e8f\u5b9a\u4f4d\u8bb0\u8f7d\u65ad\u53e3\uff0c\u518d\u8865\u5165\u7f3a\u5931\u7684\u8981\u70b9",  # 用生长阶段顺序定位记载断口，再补入缺失的要点
                        "nextSceneId": "scene-003",
                        "scoreDelta": 0,
                        "knowledgePointId": PREREQUISITE_ID
                    }
                ],
                "knowledgeBindings": [
                    {
                        "knowledgePointId": PREREQUISITE_ID,
                        "questionId": NAV_SCENE_002,
                        "purpose": "EXPLAIN"
                    }
                ]
            },
            {
                "sceneId": "scene-003",
                "title": "\u4e00\u6b21\u51b3\u5b9a",  # 一次决定
                "dialogue": [
                    {
                        "speakerId": "\u6d1b\u6069",
                        "text": "\u4e0a\u6e21\u6865\u7684\u5b88\u62a4\u8005\u9001\u4e86\u6d88\u606f\uff0c\u8c37\u5e95\u7684\u704c\u6e89\u53ea\u80fd\u7ef4\u6301\u5341\u5206\u949f\uff0c\u4e4b\u540e\u8981\u8ba9\u7ed9\u4e0a\u6e38\u7684\u6751\u5e84\u3002\u4f60\u53ea\u6709\u4e00\u6b21\u8c03\u914d\u7684\u673a\u4f1a\u3002",  # 上渡桥的守护者送了消息，谷底的灌溉只能维持十分钟，之后要让给上游的村庄。你只有一次调配的机会。
                        "emotion": "urgent"
                    },
                    {
                        "speakerId": "\u827e\u9ece",
                        "text": "\u5982\u679c\u53ea\u6d45\u704c\u4e0d\u65bd\u80a5\uff0c\u5206\u8618\u4f1a\u5f92\u957f\u4f46\u6839\u7cfb\u6d6e\u6d45\u3002\u5982\u679c\u53ea\u65bd\u80a5\u4e0d\u704c\u6c34\uff0c\u80a5\u6599\u5c01\u5728\u571f\u8868\u3002\u4f60\u5f97\u544a\u8bc9\u6211\u4eec\u600e\u4e48\u7528\u8fd9\u5341\u5206\u949f\u3002",  # 如果只浅灌不施肥，分蘖会徒长但根系浮浅。如果只施肥不灌水，肥料封在土表。你得告诉我们怎么用这十分钟。
                        "emotion": "pressured"
                    },
                    {
                        "speakerId": "\u4f60",
                        "text": "\u5206\u8618\u671f\u7684\u7ba1\u7406\u4e0d\u80fd\u53ea\u770b\u4e00\u4e2a\u65b9\u5411\u3002\u5982\u679c\u53ea\u987e\u7fa4\u4f53\u6570\u91cf\uff0c\u4e2a\u4f53\u957f\u4e0d\u58ee\uff1b\u5982\u679c\u53ea\u987e\u4e2a\u4f53\uff0c\u7fa4\u4f53\u53c8\u6563\u4e86\u3002\u6c34\u548c\u80a5\u5f97\u540c\u65f6\u8d77\u4f5c\u7528\u3002",  # 分蘖期的管理不能只看一个方向。如果只顾群体数量，个体长不壮；如果只顾个体，群体又散了。水和肥得同时起作用。
                        "emotion": "decisive"
                    }
                ],
                "choices": [
                    {
                        "choiceId": "c-scene-003-correct",
                        "questionId": QUESTION_ID,
                        "text": "\u534f\u8c03\u7fa4\u4f53\u6570\u91cf\u4e0e\u4e2a\u4f53\u751f\u957f\uff0c\u540c\u65f6\u8c03\u6574\u6c34\u80a5\u4fc3\u8fdb\u6709\u6548\u5206\u8618",  # 协调群体数量与个体生长，同时调整水肥促进有效分蘖
                        "nextSceneId": "scene-004",
                        "scoreDelta": 1,
                        "answerKind": "CHOICE",
                        "correct": True,
                        "knowledgePointId": TARGET_ID
                    },
                    {
                        "choiceId": "c-scene-003-d1",
                        "questionId": QUESTION_ID,
                        "text": DISTRACTOR_1,
                        "nextSceneId": "scene-004",
                        "scoreDelta": 0,
                        "answerKind": "CHOICE",
                        "correct": False,
                        "knowledgePointId": TARGET_ID
                    },
                    {
                        "choiceId": "c-scene-003-d2",
                        "questionId": QUESTION_ID,
                        "text": DISTRACTOR_2,
                        "nextSceneId": "scene-004",
                        "scoreDelta": 0,
                        "answerKind": "CHOICE",
                        "correct": False,
                        "knowledgePointId": TARGET_ID
                    },
                    {
                        "choiceId": "c-scene-003-d3",
                        "questionId": QUESTION_ID,
                        "text": DISTRACTOR_3,
                        "nextSceneId": "scene-004",
                        "scoreDelta": 0,
                        "answerKind": "CHOICE",
                        "correct": False,
                        "knowledgePointId": TARGET_ID
                    }
                ],
                "knowledgeBindings": [
                    {
                        "knowledgePointId": TARGET_ID,
                        "questionId": QUESTION_ID,
                        "purpose": "QUESTION"
                    }
                ]
            },
            {
                "sceneId": "scene-004",
                "title": "\u704c\u6e89\u505c\u4e0b\u4ee5\u540e",  # 灌溉停下以后
                "dialogue": [
                    {
                        "speakerId": "\u6d1b\u6069",
                        "text": "\u704c\u6e89\u505c\u4e86\uff0c\u4f46\u5206\u8618\u7684\u957f\u52bf\u548c\u6839\u7cfb\u90fd\u7b3c\u4f4f\u4e86\u3002\u8c37\u5e95\u7684\u67af\u840e\u533a\u57df\u5df2\u7ecf\u6269\u6563\u505c\u4f4f\u4e86\u3002",  # 灌溉停了，但分蘖的长势和根系都笼住了。谷底的枯萎区域已经扩散停住了。
                        "emotion": "relieved"
                    },
                    {
                        "speakerId": "\u827e\u9ece",
                        "text": "\u88ab\u6d91\u6389\u7684\u90a3\u53e5\u8bdd\u6211\u5728\u7f8a\u76ae\u7eb8\u7684\u53e6\u4e00\u9762\u627e\u5230\u4e86\u3002\u4f60\u7684\u751f\u957f\u9636\u6bb5\u8fd8\u539f\u8ba9\u6574\u4e2a\u6863\u6848\u5bf9\u4e0a\u4e86\u3002\u8fd9\u4e0d\u662f\u80cc\u4e66\uff0c\u662f\u771f\u7684\u6551\u4e86\u8c37\u5e95\u3002",  # 被涂掉的那句话我在羊皮纸的另一面找到了。你的生长阶段还原让整个档案对上了。这不是背书，是真的救了谷底。
                        "emotion": "grateful"
                    }
                ],
                "choices": [],
                "knowledgeBindings": []
            }
        ],
        "assets": [
            {"assetId": "asset-001", "type": "BACKGROUND", "uri": "assets/fantasy/bg/fantasy_tower_entrance.webp"},
            {"assetId": "asset-002", "type": "BACKGROUND", "uri": "assets/fantasy/bg/fantasy_forest_mystic.webp"},
            {"assetId": "asset-003", "type": "BACKGROUND", "uri": "assets/fantasy/bg/fantasy_star_chamber.webp"},
            {"assetId": "asset-004", "type": "CHARACTER", "uri": "assets/fantasy/char/char_elf_aria_neutral.webp"},
            {"assetId": "asset-005", "type": "CHARACTER", "uri": "assets/fantasy/char/char_elf_aria_casting.webp"},
            {"assetId": "asset-006", "type": "CHARACTER", "uri": "assets/fantasy/char/char_elf_aria_smile.webp"},
            {"assetId": "asset-007", "type": "AUDIO", "uri": "assets/fantasy/audio/bgm_fantasy_mystic.ogg"},
            {"assetId": "asset-008", "type": "AUDIO", "uri": "assets/fantasy/audio/sfx_magic_chime.ogg"},
            {"assetId": "asset-009", "type": "AUDIO", "uri": "assets/fantasy/audio/sfx_spell_cast.ogg"}
        ]
    }


def build_science_package() -> dict:
    """SCIENCE style: station hydroponics malfunction, two researchers disagree."""
    pkg_id = str(uuid.uuid4())
    return {
        "schemaVersion": "1.0",
        "packageId": pkg_id,
        "generatorVersion": GENERATOR_VERSION,
        "reviewPlanId": REVIEW_PLAN_ID,
        "snapshotVersion": SNAPSHOT_VERSION,
        "entrySceneId": "scene-001",
        "scenes": [
            {
                "sceneId": "scene-001",
                "title": "\u7eff\u8272\u9762\u677f\u7684\u95ea\u70c1",  # 绿色面板的闪烁
                "dialogue": [
                    {
                        "speakerId": "NEXUS",
                        "text": "\u6c34\u7a3b\u6c34\u57f9\u8231\u7684\u751f\u957f\u66f2\u7ebf\u51fa\u73b0\u5f02\u5e38\u4e0b\u964d\u3002\u6570\u636e\u5e93\u4e2d\u8be5\u9636\u6bb5\u7684\u8bb0\u5f55\u88ab\u6807\u8bb0\u4e3a\u5f85\u5ba1\u6838\uff0c\u539f\u56e0\u662f\u4e0a\u4e00\u73ed\u672a\u5b8c\u6210\u4ea4\u63a5\u3002",  # 水稻水培舱的生长曲线出现异常下降。数据库中该阶段的记录被标记为待审核，原因是上一班未完成交接。
                        "emotion": "alert"
                    },
                    {
                        "speakerId": "\u59da\u771f",  # 姚真
                        "text": "\u6211\u770b\u8fc7\u4e86\uff0c\u662f\u5206\u8618\u9636\u6bb5\u7684\u6570\u636e\u4e22\u5931\u4e86\u3002\u4e0a\u4e00\u73ed\u7684\u59da\u771f\u2014\u2014\u4e5f\u5c31\u662f\u6211\u2014\u2014\u5728\u5236\u51b7\u56de\u8def\u8df3\u95f8\u7684\u65f6\u5019\u6253\u5f00\u8fc7\u8231\u95e8\uff0c\u53ef\u80fd\u6296\u52a8\u4e86\u4f20\u611f\u5668\u3002",  # 我看过了，是分蘖阶段的数据丢失了。上一班的姚真——也就是我——在制冷回路跳闸的时候打开过舱门，可能抖动了传感器。
                        "emotion": "uneasy"
                    },
                    {
                        "speakerId": "\u4f60",
                        "text": "\u6c34\u7a3b\u4ece\u64ad\u79cd\u5230\u6210\u719f\u4f1a\u7ecf\u5386\u5e7c\u82d7\u671f\u3001\u5206\u8618\u671f\u3001\u62d4\u8282\u671f\u3001\u62bd\u7a57\u671f\u548c\u6210\u719f\u671f\u3002\u4e22\u5931\u7684\u5c31\u662f\u5206\u8618\u671f\u7684\u8bb0\u5f55\uff0c\u8fd9\u4e2a\u9636\u6bb5\u7684\u7ba1\u7406\u53c2\u6570\u6700\u5173\u952e\u3002",  # 水稻从播种到成熟会经历幼苗期、分蘖期、拔节期、抽穗期和成熟期。丢失的就是分蘖期的记录，这个阶段的管理参数最关键。
                        "emotion": "focused"
                    }
                ],
                "choices": [
                    {
                        "choiceId": "c-scene-001-1",
                        "questionId": NAV_SCENE_001,
                        "text": "\u5148\u6309\u751f\u957f\u9636\u6bb5\u987a\u5e8f\u68b3\u7406\u73b0\u6709\u6570\u636e\uff0c\u518d\u5b9a\u4f4d\u7f3a\u5931\u6bb5",  # 先按生长阶段顺序梳理现有数据，再定位丢失段
                        "nextSceneId": "scene-002",
                        "scoreDelta": 0,
                        "knowledgePointId": TARGET_ID
                    }
                ],
                "knowledgeBindings": [
                    {
                        "knowledgePointId": TARGET_ID,
                        "questionId": NAV_SCENE_001,
                        "purpose": "FEEDBACK"
                    }
                ]
            },
            {
                "sceneId": "scene-002",
                "title": "\u5907\u4efd\u65e5\u5fd7\u7684\u7f1d\u9699",  # 备份日志的缝隙
                "dialogue": [
                    {
                        "speakerId": "NEXUS",
                        "text": "\u5907\u4efd\u670d\u52a1\u5668\u4e2d\u68c0\u7d22\u5230\u4e86\u90e8\u5206\u5206\u8618\u671f\u8bb0\u5f55\u3002\u6570\u636e\u7247\u6bb5\u88ab\u5207\u65ad\u4e3a\u4e24\u6bb5\uff0c\u4e2d\u95f4\u6709\u4e00\u4e2a\u65f6\u95f4\u7a7a\u7f3a\u3002",  # 备份服务器中检索到了部分分蘖期记录。数据片段被切断为两段，中间有一个时间空缺。
                        "emotion": "processing"
                    },
                    {
                        "speakerId": "\u4f60",
                        "text": "\u5e7c\u82d7\u671f\u4e4b\u540e\u5c31\u662f\u5206\u8618\u671f\uff0c\u8fd9\u6bb5\u6b63\u662f\u8bb0\u5f55\u7684\u7f1d\u9699\u3002\u5982\u679c\u987a\u5e8f\u9519\u4e86\uff0c\u540e\u9762\u7684\u8425\u517b\u6db2\u6d53\u5ea6\u5224\u65ad\u90fd\u4f1a\u5931\u53bb\u53c2\u7167\u3002",  # 幼苗期之后就是分蘖期，这段正是记录的缝隙。如果顺序错了，后面的营养液浓度判断都会失去参照。
                        "emotion": "calm"
                    },
                    {
                        "speakerId": "\u59da\u771f",
                        "text": "\u6211\u5728\u672c\u5730\u7ec8\u7aef\u7684\u7f13\u5b58\u91cc\u627e\u5230\u4e86\u4e00\u6761\u672a\u540c\u6b65\u7684\u7ba1\u7406\u53c2\u6570\u8bb0\u5f55\uff0c\u4e0a\u9762\u6807\u6ce8\u7684\u662f\u5206\u8618\u671f\u7684\u8981\u70b9\u3002\u4f46\u6709\u4e00\u884c\u88ab\u4e71\u7801\u8986\u76d6\u4e86\uff0c\u4f60\u770b\u770b\u80fd\u4e0d\u80fd\u8fd8\u539f\u3002",  # 我在本地终端的缓存里找到了一条未同步的管理参数记录，上面标注的是分蘖期的要点。但有一行被乱码覆盖了，你看看能不能还原。
                        "emotion": "hopeful"
                    }
                ],
                "choices": [
                    {
                        "choiceId": "c-scene-002-1",
                        "questionId": NAV_SCENE_002,
                        "text": "\u7528\u751f\u957f\u9636\u6bb5\u987a\u5e8f\u5b9a\u4f4d\u8bb0\u5f55\u7f1d\u9699\uff0c\u518d\u8fd8\u539f\u7f3a\u5931\u7684\u53c2\u6570",  # 用生长阶段顺序定位记录缝隙，再还原丢失的参数
                        "nextSceneId": "scene-003",
                        "scoreDelta": 0,
                        "knowledgePointId": PREREQUISITE_ID
                    }
                ],
                "knowledgeBindings": [
                    {
                        "knowledgePointId": PREREQUISITE_ID,
                        "questionId": NAV_SCENE_002,
                        "purpose": "EXPLAIN"
                    }
                ]
            },
            {
                "sceneId": "scene-003",
                "title": "\u5341\u5206\u949f\u7684\u7a97\u53e3",  # 十分钟的窗口
                "dialogue": [
                    {
                        "speakerId": "NEXUS",
                        "text": "\u5236\u51b7\u56de\u8def\u7684\u9694\u79bb\u9600\u5c06\u5728\u5341\u5206\u949f\u540e\u5173\u95ed\u3002\u6b64\u671f\u95f4\u8425\u517b\u6db2\u4f9b\u5e94\u53ef\u4ee5\u91cd\u65b0\u8fde\u63a5\uff0c\u4f46\u6d53\u5ea6\u53ea\u80fd\u8c03\u4e00\u6b21\u3002",  # 制冷回路的隔离阀将在十分钟后关闭。此期间营养液供应可以重新连接，但浓度只能调一次。
                        "emotion": "warning"
                    },
                    {
                        "speakerId": "\u59da\u771f",
                        "text": "\u5982\u679c\u53ea\u8c03\u6c34\u4f4d\u4e0d\u8c03\u6d53\u5ea6\uff0c\u5206\u8618\u4f1a\u5f92\u957f\u4f46\u6839\u7cfb\u504f\u5f31\u3002\u5982\u679c\u53ea\u8c03\u6d53\u5ea6\u4e0d\u8c03\u6c34\u4f4d\uff0c\u8425\u517b\u6db2\u65e0\u6cd5\u5747\u5300\u6f2b\u900f\u3002\u4f60\u8981\u600e\u4e48\u7528\u8fd9\u4e2a\u7a97\u53e3\uff1f",  # 如果只调水位不调浓度，分蘖会徒长但根系偏弱。如果只调浓度不调水位，营养液无法均匀漫透。你要怎么用这个窗口？
                        "emotion": "pressured"
                    },
                    {
                        "speakerId": "\u4f60",
                        "text": "\u5206\u8618\u671f\u7684\u7ba1\u7406\u4e0d\u80fd\u53ea\u770b\u4e00\u4e2a\u65b9\u5411\u3002\u5982\u679c\u53ea\u987e\u7fa4\u4f53\u6570\u91cf\uff0c\u4e2a\u4f53\u957f\u4e0d\u58ee\uff1b\u5982\u679c\u53ea\u987e\u4e2a\u4f53\uff0c\u7fa4\u4f53\u53c8\u6563\u4e86\u3002\u6c34\u4f4d\u548c\u6d53\u5ea6\u5f97\u540c\u6b65\u8c03\u6574\uff0c\u4e0d\u80fd\u53ea\u52a8\u4e00\u4e2a\u53c2\u6570\u3002",  # 分蘖期的管理不能只看一个方向。如果只顾群体数量，个体长不壮；如果只顾个体，群体又散了。水位和浓度得同步调整，不能只动一个参数。
                        "emotion": "decisive"
                    }
                ],
                "choices": [
                    {
                        "choiceId": "c-scene-003-correct",
                        "questionId": QUESTION_ID,
                        "text": "\u534f\u8c03\u7fa4\u4f53\u6570\u91cf\u4e0e\u4e2a\u4f53\u751f\u957f\uff0c\u540c\u65f6\u8c03\u6574\u6c34\u80a5\u4fc3\u8fdb\u6709\u6548\u5206\u8618",  # 协调群体数量与个体生长，同时调整水肥促进有效分蘖
                        "nextSceneId": "scene-004",
                        "scoreDelta": 1,
                        "answerKind": "CHOICE",
                        "correct": True,
                        "knowledgePointId": TARGET_ID
                    },
                    {
                        "choiceId": "c-scene-003-d1",
                        "questionId": QUESTION_ID,
                        "text": DISTRACTOR_1,
                        "nextSceneId": "scene-004",
                        "scoreDelta": 0,
                        "answerKind": "CHOICE",
                        "correct": False,
                        "knowledgePointId": TARGET_ID
                    },
                    {
                        "choiceId": "c-scene-003-d2",
                        "questionId": QUESTION_ID,
                        "text": DISTRACTOR_2,
                        "nextSceneId": "scene-004",
                        "scoreDelta": 0,
                        "answerKind": "CHOICE",
                        "correct": False,
                        "knowledgePointId": TARGET_ID
                    },
                    {
                        "choiceId": "c-scene-003-d3",
                        "questionId": QUESTION_ID,
                        "text": DISTRACTOR_3,
                        "nextSceneId": "scene-004",
                        "scoreDelta": 0,
                        "answerKind": "CHOICE",
                        "correct": False,
                        "knowledgePointId": TARGET_ID
                    }
                ],
                "knowledgeBindings": [
                    {
                        "knowledgePointId": TARGET_ID,
                        "questionId": QUESTION_ID,
                        "purpose": "QUESTION"
                    }
                ]
            },
            {
                "sceneId": "scene-004",
                "title": "\u9694\u79bb\u9600\u5173\u95ed\u4ee5\u540e",  # 隔离阀关闭以后
                "dialogue": [
                    {
                        "speakerId": "NEXUS",
                        "text": "\u9694\u79bb\u9600\u5df2\u5173\u95ed\u3002\u8425\u517b\u6db2\u4f9b\u5e94\u6062\u590d\u6b63\u5e38\uff0c\u5206\u8618\u7684\u751f\u957f\u66f2\u7ebf\u56de\u5347\u3002\u4e22\u5931\u7684\u53c2\u6570\u5df2\u88ab\u672c\u5730\u7f13\u5b58\u8865\u5165\u3002",  # 隔离阀已关闭。营养液供应恢复正常，分蘖的生长曲线回升。丢失的参数已被本地缓存补入。
                        "emotion": "stable"
                    },
                    {
                        "speakerId": "\u59da\u771f",
                        "text": "\u88ab\u4e71\u7801\u8986\u76d6\u7684\u90a3\u884c\u6211\u5728\u7f13\u5b58\u7684\u5feb\u7167\u91cc\u627e\u5230\u4e86\u3002\u4f60\u7684\u751f\u957f\u9636\u6bb5\u8fd8\u539f\u8ba9\u6574\u4e2a\u6570\u636e\u5e93\u5bf9\u4e0a\u4e86\u3002\u8fd9\u4e0d\u662f\u590d\u8ff0\u624b\u518c\uff0c\u662f\u771f\u7684\u89e3\u51b3\u4e86\u95ee\u9898\u3002",  # 被乱码覆盖的那行我在缓存的快照里找到了。你的生长阶段还原让整个数据库对上了。这不是复述手册，是真的解决了问题。
                        "emotion": "grateful"
                    }
                ],
                "choices": [],
                "knowledgeBindings": []
            }
        ],
        "assets": [
            {"assetId": "asset-001", "type": "BACKGROUND", "uri": "assets/science/bg/sci_station_hub.webp"},
            {"assetId": "asset-002", "type": "BACKGROUND", "uri": "assets/science/bg/sci_station_lab.webp"},
            {"assetId": "asset-003", "type": "BACKGROUND", "uri": "assets/science/bg/sci_holographic_display.webp"},
            {"assetId": "asset-004", "type": "CHARACTER", "uri": "assets/science/char/char_nexus_hologram_blue.webp"},
            {"assetId": "asset-005", "type": "CHARACTER", "uri": "assets/science/char/char_nexus_hologram_green.webp"},
            {"assetId": "asset-006", "type": "CHARACTER", "uri": "assets/science/char/char_nexus_hologram_amber.webp"},
            {"assetId": "asset-007", "type": "AUDIO", "uri": "assets/science/audio/bgm_science_ambient.ogg"},
            {"assetId": "asset-008", "type": "AUDIO", "uri": "assets/science/audio/sfx_ui_beep.ogg"},
            {"assetId": "asset-009", "type": "AUDIO", "uri": "assets/science/audio/sfx_data_process.ogg"}
        ]
    }


# ============================================================================
# Main
# ============================================================================

def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    # Output to the same directory as this script (mocks/)
    mocks_dir = base_dir

    packages = [
        ("campus-standard-full.json", build_campus_package()),
        ("fantasy-standard-full.json", build_fantasy_package()),
        ("science-standard-full.json", build_science_package()),
    ]

    for filename, package in packages:
        path = os.path.join(mocks_dir, filename)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(package, f, ensure_ascii=False, indent=4)
        print(f"Generated: {path} ({len(package['scenes'])} scenes)")

    print(f"\nDone. {len(packages)} packages generated.")


if __name__ == "__main__":
    main()
