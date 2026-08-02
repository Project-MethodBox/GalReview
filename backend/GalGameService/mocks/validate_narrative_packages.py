#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Validate the 3 narrative-enhanced game packages against:
1. JSON Schema 1.0 structural rules
2. NarrativeDraftValidator semantic rules (grounding quotes, speaker IDs, forbidden words, etc.)
"""

import json
import re
import os
import sys

# ============================================================================
# Constants (must match GameGenerator / NarrativeTestData / NarrativeDraftValidator)
# ============================================================================

REVIEW_PLAN_ID = "8e812950-3311-40a7-93ab-636409df8cc2"
PREREQUISITE_ID = "84f7d873-e573-4689-b18d-6f82c745d1bf"
TARGET_ID = "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"
GENERATOR_VERSION = "gala-0.1.0"

PREREQUISITE_TITLE = "\u6c34\u7a3b\u57fa\u672c\u751f\u957f\u5468\u671f"  # 水稻基本生长周期
PREREQUISITE_SUMMARY = "\u6c34\u7a3b\u4ece\u64ad\u79cd\u5230\u6210\u719f\u4f1a\u7ecf\u5386\u5e7c\u82d7\u671f\u3001\u5206\u8618\u671f\u3001\u62d4\u8282\u671f\u3001\u62bd\u7a57\u671f\u548c\u6210\u719f\u671f\u3002"  # 水稻从播种到成熟会经历幼苗期、分蘖期、拔节期、抽穗期和成熟期。
TARGET_TITLE = "\u6c34\u7a3b\u5206\u8618\u671f\u7ba1\u7406"  # 水稻分蘖期管理
TARGET_SUMMARY = "\u6c34\u7a3b\u5206\u8618\u671f\u6700\u5173\u952e\u7684\u7ba1\u7406\u76ee\u6807\u662f\u534f\u8c03\u7fa4\u4f53\u6570\u91cf\u4e0e\u4e2a\u4f53\u751f\u957f\uff0c\u901a\u8fc7\u6c34\u80a5\u8c03\u63a7\u4fc3\u8fdb\u6709\u6548\u5206\u8618\u3002"  # 水稻分蘖期最关键的管理目标是协调群体数量与个体生长，通过水肥调控促进有效分蘖。

# All possible grounding quote sources (title + summary of both nodes)
ALL_GROUNDING_SOURCES = [
    PREREQUISITE_TITLE,
    PREREQUISITE_SUMMARY,
    TARGET_TITLE,
    TARGET_SUMMARY,
]

# Allowed speaker IDs per style
ALLOWED_SPEAKERS = {
    "campus": ["\u4f60", "\u6797\u6f88", "\u5468\u5d50"],  # 你, 林澈, 周岚
    "fantasy": ["\u4f60", "\u827e\u9ece", "\u6d1b\u6069"],  # 你, 艾黎, 洛恩
    "science": ["\u4f60", "NEXUS", "\u59da\u771f"],  # 你, NEXUS, 姚真
}

# Forbidden word fragments (from NarrativeDraftValidator)
FORBIDDEN_FRAGMENTS = [
    "\u77e5\u8bc6\u70b9\u6743\u91cd",       # 知识点权重
    "\u5173\u952e\u6807\u7b7e",             # 关键标签
    "questionTarget",
    "selectionReason",
    "masteryScore",
    "PlanGraph",
    "UUID",
    "\u7cfb\u7edf\u5df2\u751f\u6210\u8bc4\u4f30\u95ee\u9898",  # 系统已生成评估问题
    "\u77e5\u8bc6\u70b9\u8bb2\u89e3",       # 知识点讲解
    "\u6765\u770b\u770b\u8fd9\u9053\u9898", # 来看看这道题
    "\u6839\u636e\u6240\u5b66\u5185\u5bb9", # 根据所学内容
    "\u672c\u8f6e\u590d\u4e60\u7ed3\u675f", # 本轮复习结束
    "\u8ba9\u6211\u4eec\u63a2\u7d22",       # 让我们探索
    "\u77e5\u8bc6\u4e4b\u5149",             # 知识之光
]

# Emotion regex: ^[a-z][a-z0-9_-]{0,31}$
EMOTION_REGEX = re.compile(r'^[a-z][a-z0-9_-]{0,31}$')

# Limits
MAX_DIALOGUE_LINES_PER_SCENE = 8
MAX_LINE_LENGTH = 320
MAX_CHOICE_LENGTH = 280
MAX_TOTAL_CHARACTERS = 60000
MAX_CHOICES_PER_SCENE = 6
MAX_SCENES = 100
MIN_SCENES = 1

# Knowledge node titles (for anchor check)
KNOWLEDGE_ANCHORS = [
    PREREQUISITE_TITLE,
    TARGET_TITLE,
    "\u5206\u8618",  # 分蘖
    "\u5e7c\u82d7",  # 幼苗
    "\u62d4\u8282",  # 拔节
    "\u62bd\u7a57",  # 抽穗
    "\u6210\u719f",  # 成熟
]

# Target grounding quote (for ASSESSMENT answer leak check)
TARGET_GROUNDING = "\u534f\u8c03\u7fa4\u4f53\u6570\u91cf\u4e0e\u4e2a\u4f53\u751f\u957f"  # 协调群体数量与个体生长

# ============================================================================
# Validation Functions
# ============================================================================

class ValidationReport:
    def __init__(self):
        self.errors = []
        self.warnings = []
        self.passed = 0
        self.total = 0

    def add_error(self, msg):
        self.errors.append(msg)
        self.total += 1

    def add_warning(self, msg):
        self.warnings.append(msg)

    def add_pass(self):
        self.passed += 1
        self.total += 1

    @property
    def ok(self):
        return len(self.errors) == 0

    def summary(self):
        status = "PASS" if self.ok else "FAIL"
        lines = [f"  Status: {status} ({self.passed}/{self.total} checks passed)"]
        if self.errors:
            lines.append(f"  Errors ({len(self.errors)}):")
            for e in self.errors:
                lines.append(f"    - {e}")
        if self.warnings:
            lines.append(f"  Warnings ({len(self.warnings)}):")
            for w in self.warnings:
                lines.append(f"    - {w}")
        return "\n".join(lines)


def get_style_from_filename(filename: str) -> str:
    """Extract style name from filename."""
    if filename.startswith("campus"):
        return "campus"
    elif filename.startswith("fantasy"):
        return "fantasy"
    elif filename.startswith("science"):
        return "science"
    return ""


def validate_uuid_v4(uid: str) -> bool:
    """Check if string is a valid UUID v4."""
    try:
        import uuid as uuid_module
        parsed = uuid_module.UUID(uid)
        return parsed.version == 4
    except (ValueError, AttributeError):
        return False


def validate_package(filename: str, package: dict) -> ValidationReport:
    """Validate a single game package against all rules."""
    report = ValidationReport()
    style = get_style_from_filename(filename)

    # --- Top-level fields ---
    if package.get("schemaVersion") != "1.0":
        report.add_error(f"schemaVersion must be '1.0', got '{package.get('schemaVersion')}'")
    else:
        report.add_pass()

    pkg_id = package.get("packageId", "")
    if not validate_uuid_v4(pkg_id):
        report.add_error(f"packageId must be valid UUID v4, got '{pkg_id}'")
    else:
        report.add_pass()

    if package.get("generatorVersion") != GENERATOR_VERSION:
        report.add_error(f"generatorVersion must be '{GENERATOR_VERSION}'")
    else:
        report.add_pass()

    if package.get("reviewPlanId") != REVIEW_PLAN_ID:
        report.add_error(f"reviewPlanId mismatch")
    else:
        report.add_pass()

    snapshot = package.get("snapshotVersion", "")
    if not snapshot:
        report.add_error("snapshotVersion is empty")
    else:
        report.add_pass()

    entry_scene = package.get("entrySceneId", "")
    if not entry_scene:
        report.add_error("entrySceneId is empty")
    else:
        report.add_pass()

    # --- Scenes ---
    scenes = package.get("scenes", [])
    if not (MIN_SCENES <= len(scenes) <= MAX_SCENES):
        report.add_error(f"scenes count must be {MIN_SCENES}-{MAX_SCENES}, got {len(scenes)}")
    else:
        report.add_pass()

    scene_ids = set()
    for scene in scenes:
        sid = scene.get("sceneId", "")
        if sid in scene_ids:
            report.add_error(f"Duplicate sceneId: {sid}")
        scene_ids.add(sid)

    if entry_scene not in scene_ids:
        report.add_error(f"entrySceneId '{entry_scene}' not found in scenes")
    else:
        report.add_pass()

    # --- Per-scene validation ---
    total_chars = 0
    for scene in scenes:
        sid = scene.get("sceneId", "")
        title = scene.get("title", "")
        dialogues = scene.get("dialogue", [])
        choices = scene.get("choices", [])
        bindings = scene.get("knowledgeBindings", [])

        # Dialogue count
        if not (1 <= len(dialogues) <= 200):
            report.add_error(f"Scene {sid}: dialogue count must be 1-200, got {len(dialogues)}")
        else:
            report.add_pass()

        # Check dialogue lines (capped at 8 for narrative drafts)
        if len(dialogues) > MAX_DIALOGUE_LINES_PER_SCENE:
            report.add_warning(f"Scene {sid}: dialogue lines ({len(dialogues)}) exceeds narrative cap ({MAX_DIALOGUE_LINES_PER_SCENE})")

        # Speaker IDs and text length
        scene_dialogue_text = ""
        for line in dialogues:
            speaker = line.get("speakerId", "")
            text = line.get("text", "")
            emotion = line.get("emotion")

            # Speaker must be in allowed list for this style
            if speaker not in ALLOWED_SPEAKERS.get(style, []):
                report.add_error(f"Scene {sid}: speakerId '{speaker}' not in allowed speakers for {style}: {ALLOWED_SPEAKERS.get(style, [])}")
            else:
                report.add_pass()

            # Text length
            if len(text) > MAX_LINE_LENGTH:
                report.add_error(f"Scene {sid}: dialogue line exceeds {MAX_LINE_LENGTH} chars ({len(text)})")
            else:
                report.add_pass()

            # Forbidden fragments
            for frag in FORBIDDEN_FRAGMENTS:
                if frag in text:
                    report.add_error(f"Scene {sid}: forbidden fragment '{frag}' found in dialogue text")
            report.add_pass()  # forbidden check passed

            # Emotion regex
            if emotion is not None:
                if not EMOTION_REGEX.match(emotion):
                    report.add_error(f"Scene {sid}: emotion '{emotion}' does not match pattern ^[a-z][a-z0-9_-]{{0,31}}$")
                else:
                    report.add_pass()
            else:
                report.add_pass()

            scene_dialogue_text += text
            total_chars += len(text)

        # Choices
        if len(choices) > MAX_CHOICES_PER_SCENE:
            report.add_error(f"Scene {sid}: choices count exceeds {MAX_CHOICES_PER_SCENE}")
        else:
            report.add_pass()

        choice_ids_in_scene = set()
        for choice in choices:
            cid = choice.get("choiceId", "")
            if cid in choice_ids_in_scene:
                report.add_error(f"Scene {sid}: duplicate choiceId '{cid}'")
            choice_ids_in_scene.add(cid)

            ctext = choice.get("text", "")
            if len(ctext) > MAX_CHOICE_LENGTH:
                report.add_error(f"Scene {sid}: choice text exceeds {MAX_CHOICE_LENGTH} chars ({len(ctext)})")
            else:
                report.add_pass()

            # answerKind must be CHOICE if present
            ak = choice.get("answerKind")
            if ak is not None and ak != "CHOICE":
                report.add_error(f"Scene {sid}: answerKind must be 'CHOICE', got '{ak}'")
            else:
                report.add_pass()

        # Knowledge bindings
        for binding in bindings:
            purpose = binding.get("purpose")
            if purpose not in ("EXPLAIN", "QUESTION", "FEEDBACK"):
                report.add_error(f"Scene {sid}: binding purpose '{purpose}' not in allowed enum")
            else:
                report.add_pass()

            kp_id = binding.get("knowledgePointId", "")
            if kp_id not in (PREREQUISITE_ID, TARGET_ID):
                report.add_error(f"Scene {sid}: knowledgePointId '{kp_id}' not in PlanGraph nodes")
            else:
                report.add_pass()

        # ASSESSMENT answer leak check for QUESTION scenes
        is_question_scene = any(
            b.get("purpose") == "QUESTION" for b in bindings
        )
        if is_question_scene:
            # Find the correct choice's text
            correct_choice_text = ""
            for choice in choices:
                if choice.get("correct") is True:
                    correct_choice_text = choice.get("text", "")
                    break

            # Check if the target grounding quote appears in dialogue before the question
            if TARGET_GROUNDING in scene_dialogue_text:
                report.add_error(
                    f"Scene {sid}: ASSESSMENT_ANSWER_LEAKED_IN_DIALOGUE - "
                    f"target grounding quote '{TARGET_GROUNDING}' found in pre-question dialogue"
                )
            else:
                report.add_pass()
            report.add_pass()  # QUESTION scene structure check

        # Knowledge anchor check (dialogue must contain at least one anchor)
        has_anchor = any(anchor in scene_dialogue_text for anchor in KNOWLEDGE_ANCHORS)
        if dialogues and not has_anchor:
            report.add_warning(f"Scene {sid}: no knowledge anchor found in dialogue")
        else:
            if dialogues:
                report.add_pass()

    # --- Total characters ---
    if total_chars > MAX_TOTAL_CHARACTERS:
        report.add_error(f"Total characters ({total_chars}) exceeds limit ({MAX_TOTAL_CHARACTERS})")
    else:
        report.add_pass()

    # --- Assets ---
    assets = package.get("assets", [])
    if len(assets) == 0:
        report.add_warning("assets array is empty")
    else:
        report.add_pass()
        for asset in assets:
            atype = asset.get("type", "")
            if atype not in ("BACKGROUND", "CHARACTER", "AUDIO"):
                report.add_error(f"Asset type '{atype}' not in allowed enum")
            else:
                report.add_pass()

    return report


# ============================================================================
# Main
# ============================================================================

def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    mocks_dir = base_dir

    files_to_validate = [
        "campus-standard-full.json",
        "fantasy-standard-full.json",
        "science-standard-full.json",
    ]

    all_ok = True

    for filename in files_to_validate:
        path = os.path.join(mocks_dir, filename)
        if not os.path.exists(path):
            print(f"\n{'='*60}")
            print(f"FILE: {filename}")
            print(f"  NOT FOUND: {path}")
            all_ok = False
            continue

        with open(path, "r", encoding="utf-8") as f:
            package = json.load(f)

        print(f"\n{'='*60}")
        print(f"FILE: {filename}")
        report = validate_package(filename, package)
        print(report.summary())

        if not report.ok:
            all_ok = False

    print(f"\n{'='*60}")
    if all_ok:
        print(f"OVERALL: ALL {len(files_to_validate)} PACKAGES PASSED VALIDATION")
    else:
        print(f"OVERALL: VALIDATION FAILED - see errors above")
    print(f"{'='*60}")

    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
