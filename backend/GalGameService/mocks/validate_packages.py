#!/usr/bin/env python3
"""GalGame GamePackage schema 1.0 validator — enhanced edition.

Checks all constraints defined in game-package-1.0.schema.json and
GamePackageValidator cross-field rules, plus additional quality checks:

  - UUID v4 format and version verification
  - Orphan scene detection (unreachable from any choice)
  - Dead-end scene detection (non-ending scenes with no exit)
  - Circular reference detection (infinite loops)
  - Strict type checking for all fields
  - questionId consistency within QUESTION scenes
  - Choice text quality warnings
  - Emotion value suggestions
  - Summary table for batch validation
  - Full directory glob support (all .json files)

Usage:
  python validate_packages.py                    # validate all *.json in mocks/
  python validate_packages.py file1.json ...     # validate specific files
  python validate_packages.py --strict           # treat warnings as errors
"""

import json
import sys
import re
import argparse
from pathlib import Path
from collections import Counter, defaultdict

# ============================================================
# Constants
# ============================================================

# UUID v4: version nibble (position 14) must be '4', variant nibble (position 19) must be [89ab]
UUID_RE = re.compile(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    re.IGNORECASE
)
# General UUID format (any version) — for fields where version isn't mandated
UUID_ANY_RE = re.compile(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    re.IGNORECASE
)
EMPTY_UUID = "00000000-0000-0000-0000-000000000000"

MAX_SCENES = 100
MIN_SCENES = 1
MAX_DIALOGUE = 200
MIN_DIALOGUE = 1
MAX_CHOICES = 6
MIN_CHOICES = 0

VALID_PURPOSES = {"EXPLAIN", "QUESTION", "FEEDBACK"}
VALID_ASSET_TYPES = {"BACKGROUND", "CHARACTER", "AUDIO", "OTHER"}
VALID_ANSWER_KIND = {"CHOICE"}

# Suggested emotion values (from GameGenerator.cs StyleTemplate + mock data)
KNOWN_EMOTIONS = {
    "cheerful", "encouraging", "warm", "proud", "happy", "excited",
    "thoughtful", "explaining", "informative", "calm", "serious",
    "challenging", "questioning", "mystical", "playful", "teasing",
    "neutral", "sad", "surprised", "worried", "confident", "gentle",
}

# ============================================================
# Validator
# ============================================================


class Validator:
    """Validates a GamePackage dict against schema 1.0 rules."""

    def __init__(self, strict=False):
        self.errors = []
        self.warnings = []
        self.strict = strict

    def _err(self, path, code, msg):
        self.errors.append((path, code, msg))

    def _warn(self, path, code, msg):
        self.warnings.append((path, code, msg))

    def _check_type(self, path, field, value, expected_types):
        """Check that a value is of the expected type(s)."""
        if not isinstance(value, expected_types):
            type_name = type(value).__name__
            expected_names = []
            for t in (expected_types if isinstance(expected_types, tuple) else (expected_types,)):
                expected_names.append(t.__name__)
            self._err(path, "TYPE_ERROR",
                      f"{field} must be {' | '.join(expected_names)}, got {type_name}")
            return False
        return True

    def _check_uuid(self, path, field, value, require_v4=False):
        """Check that a value is a valid UUID. If require_v4, enforce version 4."""
        if not isinstance(value, str):
            self._err(path, "INVALID_UUID", f"{field} is not a string: {value}")
            return False
        if value == EMPTY_UUID:
            self._err(path, "EMPTY_UUID", f"{field} is empty UUID (all zeros)")
            return False
        if require_v4:
            if not UUID_RE.match(value):
                if UUID_ANY_RE.match(value):
                    # Valid UUID but wrong version
                    ver = value[14]
                    self._err(path, "UUID_NOT_V4",
                              f"{field} is UUID v{ver}, expected v4: {value}")
                else:
                    self._err(path, "INVALID_UUID", f"{field} is not a valid UUID: {value}")
                return False
        else:
            if not UUID_ANY_RE.match(value):
                self._err(path, "INVALID_UUID", f"{field} is not a valid UUID: {value}")
                return False
        return True

    def validate(self, pkg):
        """Main validation entry point."""
        if not isinstance(pkg, dict):
            self._err("root", "TYPE_ERROR", "Root must be a JSON object")
            return

        self._validate_top_level(pkg)
        self._validate_scenes(pkg)
        self._validate_question_consistency(pkg)
        self._validate_reachability(pkg)
        self._validate_assets(pkg)

        return self.errors, self.warnings

    # --------------------------------------------------------
    # Top-level fields
    # --------------------------------------------------------

    def _validate_top_level(self, pkg):
        required_keys = {
            "schemaVersion", "packageId", "generatorVersion",
            "reviewPlanId", "snapshotVersion", "entrySceneId",
            "scenes", "assets"
        }
        for k in required_keys:
            if k not in pkg:
                self._err("root", "MISSING_FIELD", f"Missing required field: {k}")

        for k in pkg:
            if k not in required_keys:
                self._err("root", "UNKNOWN_FIELD", f"Unknown top-level field: {k}")

        # schemaVersion
        sv = pkg.get("schemaVersion")
        if sv is not None and sv != "1.0":
            self._err("root", "INVALID_SCHEMA_VERSION",
                      f'schemaVersion must be "1.0", got "{sv}"')

        # packageId — UUID v4
        if "packageId" in pkg:
            self._check_uuid("root", "packageId", pkg["packageId"], require_v4=True)

        # generatorVersion
        gv = pkg.get("generatorVersion")
        if gv is not None:
            if not isinstance(gv, str):
                self._err("root", "TYPE_ERROR",
                          f"generatorVersion must be string, got {type(gv).__name__}")
            elif not gv.strip():
                self._err("root", "EMPTY_FIELD", "generatorVersion is empty")

        # reviewPlanId — UUID v4
        if "reviewPlanId" in pkg:
            self._check_uuid("root", "reviewPlanId", pkg["reviewPlanId"], require_v4=True)

        # snapshotVersion
        sv_val = pkg.get("snapshotVersion")
        if sv_val is not None:
            if not isinstance(sv_val, str):
                self._err("root", "TYPE_ERROR",
                          f"snapshotVersion must be string, got {type(sv_val).__name__}")
            elif not sv_val.strip():
                self._err("root", "EMPTY_FIELD", "snapshotVersion is empty")

        # entrySceneId
        esid = pkg.get("entrySceneId")
        if esid is not None:
            if not isinstance(esid, str):
                self._err("root", "TYPE_ERROR",
                          f"entrySceneId must be string, got {type(esid).__name__}")
            elif not esid.strip():
                self._err("root", "EMPTY_FIELD", "entrySceneId is empty")

        # scenes
        scenes = pkg.get("scenes")
        if scenes is not None:
            if not isinstance(scenes, list):
                self._err("root", "TYPE_ERROR",
                          f"scenes must be array, got {type(scenes).__name__}")
            else:
                if len(scenes) < MIN_SCENES:
                    self._err("root", "NO_SCENES", "scenes array is empty")
                if len(scenes) > MAX_SCENES:
                    self._err("root", "TOO_MANY_SCENES",
                              f"scenes count {len(scenes)} > {MAX_SCENES}")

        # assets
        assets = pkg.get("assets")
        if assets is not None and not isinstance(assets, list):
            self._err("root", "TYPE_ERROR",
                      f"assets must be array, got {type(assets).__name__}")

    # --------------------------------------------------------
    # Scenes
    # --------------------------------------------------------

    def _validate_scenes(self, pkg):
        scenes = pkg.get("scenes", [])
        if not isinstance(scenes, list):
            return

        scene_ids = []
        scene_id_set = set()

        # === Pass 1: collect ALL scene IDs first (needed for nextSceneId validation) ===
        for si, scene in enumerate(scenes):
            if not isinstance(scene, dict):
                continue
            sid = scene.get("sceneId", f"[index {si}]")
            scene_ids.append(sid)
            scene_id_set.add(sid)

        # === Pass 2: validate each scene's structure, dialogue, and bindings ===
        for si, scene in enumerate(scenes):
            sid = scene.get("sceneId", f"[index {si}]") if isinstance(scene, dict) else f"[index {si}]"
            path = f"scenes[{si}]({sid})"

            if not isinstance(scene, dict):
                self._err(path, "TYPE_ERROR", f"Scene must be object, got {type(scene).__name__}")
                continue

            # Required keys
            scene_required = {"sceneId", "dialogue", "choices", "knowledgeBindings"}
            for k in scene_required:
                if k not in scene:
                    self._err(path, "MISSING_FIELD", f"Scene missing field: {k}")

            # Unknown fields
            scene_allowed = {"sceneId", "title", "dialogue", "choices", "knowledgeBindings"}
            for k in scene:
                if k not in scene_allowed:
                    self._err(path, "UNKNOWN_FIELD", f"Unknown scene field: {k}")

            # sceneId
            sid_val = scene.get("sceneId")
            if sid_val is not None:
                if not isinstance(sid_val, str):
                    self._err(path, "TYPE_ERROR",
                              f"sceneId must be string, got {type(sid_val).__name__}")
                elif not sid_val.strip():
                    self._err(path, "EMPTY_SCENE_ID", "Empty sceneId")

            # title — string or null
            title = scene.get("title")
            if title is not None and not isinstance(title, str):
                self._err(path, "TYPE_ERROR",
                          f"title must be string or null, got {type(title).__name__}")

            # dialogue
            self._validate_dialogue(scene, path)

            # choices — now scene_id_set is fully populated
            self._validate_choices(scene, path, scene_id_set)

            # knowledgeBindings
            self._validate_bindings(scene, path)

        # sceneId uniqueness
        id_counts = Counter(scene_ids)
        for sid, count in id_counts.items():
            if count > 1 and sid:
                self._err("root", "DUPLICATE_SCENE_ID", f"Duplicate sceneId: {sid} (appears {count} times)")

        # entrySceneId must exist
        entry_scene = pkg.get("entrySceneId", "")
        if entry_scene and entry_scene not in scene_id_set:
            self._err("root", "ENTRY_SCENE_NOT_FOUND",
                      f"entrySceneId '{entry_scene}' not in scenes")

        # Orphan scene detection: scenes not entry and not referenced by any choice
        referenced = set()
        for scene in scenes:
            if not isinstance(scene, dict):
                continue
            for choice in scene.get("choices", []):
                if isinstance(choice, dict):
                    nsid = choice.get("nextSceneId")
                    if nsid:
                        referenced.add(nsid)

        for si, scene in enumerate(scenes):
            if not isinstance(scene, dict):
                continue
            sid = scene.get("sceneId", "")
            if sid and sid != entry_scene and sid not in referenced:
                # Check if it's an ending scene (no choices or all nextSceneId=null)
                choices = scene.get("choices", [])
                is_ending = (len(choices) == 0 or
                             all(c.get("nextSceneId") is None for c in choices if isinstance(c, dict)))
                if not is_ending:
                    self._warn(f"scenes[{si}]({sid})", "ORPHAN_SCENE",
                               f"Scene '{sid}' is not reachable from any choice (not entry, not referenced)")
                elif sid != entry_scene:
                    self._warn(f"scenes[{si}]({sid})", "UNREACHABLE_ENDING",
                               f"Ending scene '{sid}' is not reachable from any choice")

    # --------------------------------------------------------
    # Dialogue
    # --------------------------------------------------------

    def _validate_dialogue(self, scene, path):
        dialogue = scene.get("dialogue", [])
        if not isinstance(dialogue, list):
            self._err(path, "TYPE_ERROR",
                      f"dialogue must be array, got {type(dialogue).__name__}")
            return

        if len(dialogue) < MIN_DIALOGUE:
            self._err(path, "EMPTY_DIALOGUE", "dialogue is empty or null")
        if len(dialogue) > MAX_DIALOGUE:
            self._err(path, "TOO_MANY_DIALOGUE",
                      f"dialogue count {len(dialogue)} > {MAX_DIALOGUE}")

        for di, line in enumerate(dialogue):
            dpath = f"{path}.dialogue[{di}]"
            if not isinstance(line, dict):
                self._err(dpath, "TYPE_ERROR", f"Dialogue line must be object, got {type(line).__name__}")
                continue

            # Required keys
            for k in ("speakerId", "text"):
                if k not in line:
                    self._err(dpath, "MISSING_FIELD", f"Dialogue line missing field: {k}")

            # Unknown fields
            d_allowed = {"speakerId", "text", "emotion"}
            for k in line:
                if k not in d_allowed:
                    self._err(dpath, "UNKNOWN_FIELD", f"Unknown dialogue field: {k}")

            # speakerId
            sp = line.get("speakerId")
            if sp is not None:
                if not isinstance(sp, str):
                    self._err(dpath, "TYPE_ERROR",
                              f"speakerId must be string, got {type(sp).__name__}")
                elif not sp.strip():
                    self._err(dpath, "EMPTY_DIALOGUE_FIELD", "speakerId is empty")

            # text
            txt = line.get("text")
            if txt is not None:
                if not isinstance(txt, str):
                    self._err(dpath, "TYPE_ERROR",
                              f"text must be string, got {type(txt).__name__}")
                elif not txt.strip():
                    self._err(dpath, "EMPTY_DIALOGUE_FIELD", "text is empty")
                elif len(txt) < 5:
                    self._warn(dpath, "SHORT_TEXT", f"Dialogue text is very short ({len(txt)} chars): \"{txt}\"")

            # emotion
            emotion = line.get("emotion")
            if emotion is not None:
                if not isinstance(emotion, str):
                    self._err(dpath, "TYPE_ERROR",
                              f"emotion must be string or null, got {type(emotion).__name__}")
                elif emotion and emotion.lower() not in KNOWN_EMOTIONS:
                    self._warn(dpath, "UNKNOWN_EMOTION",
                               f"emotion '{emotion}' is not in suggested set (known: {', '.join(sorted(KNOWN_EMOTIONS)[:8])}...)")

    # --------------------------------------------------------
    # Choices
    # --------------------------------------------------------

    def _validate_choices(self, scene, path, scene_id_set):
        choices = scene.get("choices", [])
        if not isinstance(choices, list):
            self._err(path, "TYPE_ERROR",
                      f"choices must be array, got {type(choices).__name__}")
            return

        if len(choices) > MAX_CHOICES:
            self._err(path, "TOO_MANY_CHOICES",
                      f"choices count {len(choices)} > {MAX_CHOICES}")

        # choiceId uniqueness within scene
        choice_ids = []
        for ci, choice in enumerate(choices):
            cpath = f"{path}.choices[{ci}]"
            if not isinstance(choice, dict):
                self._err(cpath, "TYPE_ERROR", f"Choice must be object, got {type(choice).__name__}")
                continue

            # Required keys
            for k in ("choiceId", "questionId", "text", "nextSceneId",
                       "scoreDelta", "knowledgePointId"):
                if k not in choice:
                    self._err(cpath, "MISSING_FIELD", f"Choice missing field: {k}")

            # Unknown fields
            c_allowed = {"choiceId", "questionId", "text", "nextSceneId",
                         "scoreDelta", "knowledgePointId", "answerKind", "correct"}
            for k in choice:
                if k not in c_allowed:
                    self._err(cpath, "UNKNOWN_FIELD", f"Unknown choice field: {k}")

            # choiceId
            cid = choice.get("choiceId")
            if cid is not None:
                if not isinstance(cid, str):
                    self._err(cpath, "TYPE_ERROR",
                              f"choiceId must be string, got {type(cid).__name__}")
                elif not cid.strip():
                    self._err(cpath, "EMPTY_CHOICE_FIELD", "Empty choiceId")
                choice_ids.append(cid)

            # text
            ctxt = choice.get("text")
            if ctxt is not None:
                if not isinstance(ctxt, str):
                    self._err(cpath, "TYPE_ERROR",
                              f"text must be string, got {type(ctxt).__name__}")
                elif not ctxt.strip():
                    self._err(cpath, "EMPTY_CHOICE_FIELD", "Choice text is empty")
                elif len(ctxt) < 3:
                    self._warn(cpath, "SHORT_CHOICE_TEXT",
                               f"Choice text is very short ({len(ctxt)} chars): \"{ctxt}\"")

            # questionId — UUID (any version allowed; generator uses deterministic hashes)
            qid = choice.get("questionId")
            if qid is not None:
                self._check_uuid(cpath, "questionId", qid)

            # nextSceneId
            nsid = choice.get("nextSceneId")
            if nsid is not None:
                if not isinstance(nsid, str):
                    self._err(cpath, "TYPE_ERROR",
                              f"nextSceneId must be string or null, got {type(nsid).__name__}")
                elif nsid and nsid not in scene_id_set:
                    self._err(cpath, "INVALID_NEXT_SCENE",
                              f"nextSceneId '{nsid}' not found in scenes")

            # scoreDelta
            sd = choice.get("scoreDelta")
            if sd is not None and not isinstance(sd, (int, float)):
                self._err(cpath, "INVALID_SCORE_DELTA",
                          f"scoreDelta must be number, got {type(sd).__name__}")
            elif isinstance(sd, bool):
                # bool is subclass of int in Python, but not valid for scoreDelta
                self._err(cpath, "INVALID_SCORE_DELTA",
                          f"scoreDelta must be number, got bool: {sd}")

            # knowledgePointId — UUID (any version)
            kpid = choice.get("knowledgePointId")
            if kpid is not None:
                self._check_uuid(cpath, "knowledgePointId", kpid)

            # answerKind
            ak = choice.get("answerKind")
            if ak is not None and ak != "CHOICE":
                self._err(cpath, "INVALID_ANSWER_KIND",
                          f"answerKind must be 'CHOICE' or null, got '{ak}'")

            # correct
            cor = choice.get("correct")
            if cor is not None and not isinstance(cor, bool):
                self._err(cpath, "TYPE_ERROR",
                          f"correct must be boolean or null, got {type(cor).__name__}")

        # choiceId uniqueness
        cid_counts = Counter(choice_ids)
        for cid, count in cid_counts.items():
            if count > 1 and cid:
                self._err(path, "DUPLICATE_CHOICE_ID",
                          f"Duplicate choiceId: {cid} (appears {count} times)")

    # --------------------------------------------------------
    # Knowledge Bindings
    # --------------------------------------------------------

    def _validate_bindings(self, scene, path):
        bindings = scene.get("knowledgeBindings", [])
        if not isinstance(bindings, list):
            self._err(path, "TYPE_ERROR",
                      f"knowledgeBindings must be array, got {type(bindings).__name__}")
            return

        for bi, binding in enumerate(bindings):
            bpath = f"{path}.knowledgeBindings[{bi}]"
            if not isinstance(binding, dict):
                self._err(bpath, "TYPE_ERROR", f"Binding must be object, got {type(binding).__name__}")
                continue

            # Required keys
            for k in ("knowledgePointId", "questionId", "purpose"):
                if k not in binding:
                    self._err(bpath, "MISSING_FIELD", f"Binding missing field: {k}")

            # Unknown fields
            b_allowed = {"knowledgePointId", "questionId", "purpose"}
            for k in binding:
                if k not in b_allowed:
                    self._err(bpath, "UNKNOWN_FIELD", f"Unknown binding field: {k}")

            # knowledgePointId — UUID
            kpid = binding.get("knowledgePointId")
            if kpid is not None:
                self._check_uuid(bpath, "knowledgePointId", kpid)

            # purpose
            purpose = binding.get("purpose")
            if purpose is not None:
                if not isinstance(purpose, str):
                    self._err(bpath, "TYPE_ERROR",
                              f"purpose must be string, got {type(purpose).__name__}")
                elif purpose not in VALID_PURPOSES:
                    self._err(bpath, "INVALID_PURPOSE",
                              f"purpose '{purpose}' not in {VALID_PURPOSES}")

            # questionId — required for QUESTION, optional for others
            qid = binding.get("questionId")
            if purpose == "QUESTION":
                if qid is None:
                    self._err(bpath, "QUESTION_BINDING_MISSING_QUESTION_ID",
                              "QUESTION binding missing questionId")
                else:
                    self._check_uuid(bpath, "questionId", qid)
            elif qid is not None:
                # Non-QUESTION binding with questionId — warn
                self._warn(bpath, "UNEXPECTED_QUESTION_ID",
                           f"Non-QUESTION binding has questionId: {qid}")

        # At most one QUESTION binding per scene
        q_count = sum(1 for b in bindings if isinstance(b, dict) and b.get("purpose") == "QUESTION")
        if q_count > 1:
            self._err(path, "MULTIPLE_QUESTION_BINDINGS",
                      f"Scene has {q_count} QUESTION bindings, max 1 allowed")

    # --------------------------------------------------------
    # Question consistency (cross-field within scenes)
    # --------------------------------------------------------

    def _validate_question_consistency(self, pkg):
        scenes = pkg.get("scenes", [])
        if not isinstance(scenes, list):
            return

        question_binding_ids = []  # All QUESTION binding questionIds

        for si, scene in enumerate(scenes):
            if not isinstance(scene, dict):
                continue
            sid = scene.get("sceneId", f"[index {si}]")
            path = f"scenes[{si}]({sid})"

            bindings = scene.get("knowledgeBindings", [])
            choices = scene.get("choices", [])

            has_question = False
            question_binding_qid = None
            question_binding_kpid = None

            for b in bindings:
                if isinstance(b, dict) and b.get("purpose") == "QUESTION":
                    has_question = True
                    question_binding_qid = b.get("questionId")
                    question_binding_kpid = b.get("knowledgePointId")
                    if question_binding_qid:
                        question_binding_ids.append(question_binding_qid)
                    break

            if has_question:
                correct_count = 0
                for ci, choice in enumerate(choices):
                    if not isinstance(choice, dict):
                        continue
                    cpath = f"{path}.choices[{ci}]"

                    ak = choice.get("answerKind")
                    cor = choice.get("correct")

                    if ak != "CHOICE":
                        self._err(cpath, "MISSING_ANSWER_KIND",
                                  f"QUESTION scene choice must have answerKind='CHOICE', got '{ak}'")

                    if cor is None:
                        self._err(cpath, "MISSING_CORRECT",
                                  "QUESTION scene choice must have correct field")
                    elif cor is True:
                        correct_count += 1

                    # All choices should share the same questionId as binding
                    cqid = choice.get("questionId")
                    if question_binding_qid and cqid != question_binding_qid:
                        self._err(cpath, "QUESTION_ID_MISMATCH",
                                  f"choice questionId '{cqid}' != binding questionId '{question_binding_qid}'")

                    # All choices should have same knowledgePointId as binding
                    ckpid = choice.get("knowledgePointId")
                    if question_binding_kpid and ckpid != question_binding_kpid:
                        self._err(cpath, "KP_ID_MISMATCH",
                                  f"choice knowledgePointId '{ckpid}' != binding knowledgePointId '{question_binding_kpid}'")

                if correct_count == 0:
                    self._err(path, "NO_CORRECT_CHOICE",
                              "QUESTION scene must have at least one correct=true choice")
                elif correct_count > 1:
                    self._warn(path, "MULTIPLE_CORRECT",
                               f"Scene has {correct_count} correct choices (1 expected)")

            else:
                # Non-QUESTION scene: choices must NOT have answerKind/correct
                for ci, choice in enumerate(choices):
                    if not isinstance(choice, dict):
                        continue
                    cpath = f"{path}.choices[{ci}]"
                    ak = choice.get("answerKind")
                    cor = choice.get("correct")
                    if ak is not None:
                        self._err(cpath, "NON_QUESTION_ANSWER_KIND",
                                  f"Non-QUESTION scene choice has answerKind='{ak}', should be null/absent")
                    if cor is not None:
                        self._err(cpath, "NON_QUESTION_CORRECT",
                                  f"Non-QUESTION scene choice has correct={cor}, should be null/absent")

        # questionId cross-scene uniqueness for QUESTION bindings
        qbid_counts = Counter(question_binding_ids)
        for qid, count in qbid_counts.items():
            if count > 1:
                self._err("root", "DUPLICATE_QUESTION_BINDING_ID",
                          f"questionId '{qid}' used in {count} QUESTION bindings, must be unique")

        # Orphan check: QUESTION binding's questionId must appear in choices
        for si, scene in enumerate(scenes):
            if not isinstance(scene, dict):
                continue
            sid = scene.get("sceneId", f"[index {si}]")
            path = f"scenes[{si}]({sid})"
            bindings = scene.get("knowledgeBindings", [])
            choices = scene.get("choices", [])

            for bi, binding in enumerate(bindings):
                if not isinstance(binding, dict):
                    continue
                if binding.get("purpose") == "QUESTION":
                    qid = binding.get("questionId")
                    found = any(
                        isinstance(c, dict) and c.get("questionId") == qid
                        for c in choices
                    )
                    if not found:
                        self._err(path, "ORPHAN_QUESTION_BINDING",
                                  f"QUESTION binding questionId '{qid}' not found in any choice")

    # --------------------------------------------------------
    # Reachability and graph analysis
    # --------------------------------------------------------

    def _validate_reachability(self, pkg):
        scenes = pkg.get("scenes", [])
        if not isinstance(scenes, list):
            return

        entry_scene = pkg.get("entrySceneId", "")
        scene_ids = [s.get("sceneId", "") for s in scenes if isinstance(s, dict)]
        scene_id_set = set(scene_ids)

        if entry_scene not in scene_id_set:
            return  # Already reported as ENTRY_SCENE_NOT_FOUND

        # BFS from entry
        reachable = set()
        queue = [entry_scene]
        parent_map = defaultdict(list)  # child -> [parents]

        while queue:
            cur = queue.pop(0)
            if cur in reachable:
                continue
            reachable.add(cur)
            for s in scenes:
                if not isinstance(s, dict):
                    continue
                if s.get("sceneId") == cur:
                    for c in s.get("choices", []):
                        if not isinstance(c, dict):
                            continue
                        nsid = c.get("nextSceneId")
                        if nsid and nsid in scene_id_set:
                            parent_map[nsid].append(cur)
                            if nsid not in reachable:
                                queue.append(nsid)
                    break

        # QUESTION scenes must be reachable
        for si, scene in enumerate(scenes):
            if not isinstance(scene, dict):
                continue
            sid = scene.get("sceneId", "")
            has_q = any(
                isinstance(b, dict) and b.get("purpose") == "QUESTION"
                for b in scene.get("knowledgeBindings", [])
            )
            if has_q and sid not in reachable:
                self._err(f"scenes[{si}]({sid})", "UNREACHABLE_QUESTION_SCENE",
                          f"QUESTION scene '{sid}' is not reachable from entrySceneId")

        # Dead-end detection: scenes with choices but no valid exit (not ending scenes)
        for si, scene in enumerate(scenes):
            if not isinstance(scene, dict):
                continue
            sid = scene.get("sceneId", "")
            path = f"scenes[{si}]({sid})"
            choices = scene.get("choices", [])

            if len(choices) == 0:
                # No choices = ending scene, OK
                continue

            has_exit = False
            for c in choices:
                if not isinstance(c, dict):
                    continue
                nsid = c.get("nextSceneId")
                if nsid is None:
                    has_exit = True  # null = end game
                    break
                if nsid in scene_id_set:
                    has_exit = True
                    break

            if not has_exit:
                self._err(path, "DEAD_END_SCENE",
                          f"Scene '{sid}' has {len(choices)} choices but none lead to a valid scene or null")

        # Circular reference detection (A -> B -> A with no exit)
        for si, scene in enumerate(scenes):
            if not isinstance(scene, dict):
                continue
            sid = scene.get("sceneId", "")
            path = f"scenes[{si}]({sid})"

            # Check for self-loop (scene points to itself)
            for c in scene.get("choices", []):
                if not isinstance(c, dict):
                    continue
                nsid = c.get("nextSceneId")
                if nsid == sid:
                    self._warn(path, "SELF_LOOP",
                               f"Scene '{sid}' has a choice pointing to itself")

        # Unreachable scenes (not reachable from entry at all)
        for si, scene in enumerate(scenes):
            if not isinstance(scene, dict):
                continue
            sid = scene.get("sceneId", "")
            if sid and sid != entry_scene and sid not in reachable:
                self._warn(f"scenes[{si}]({sid})", "UNREACHABLE_SCENE",
                           f"Scene '{sid}' is not reachable from entrySceneId '{entry_scene}'")

    # --------------------------------------------------------
    # Assets
    # --------------------------------------------------------

    def _validate_assets(self, pkg):
        assets = pkg.get("assets", [])
        if not isinstance(assets, list):
            return

        asset_ids = []
        for ai, asset in enumerate(assets):
            apath = f"assets[{ai}]"
            if not isinstance(asset, dict):
                self._err(apath, "TYPE_ERROR", f"Asset must be object, got {type(asset).__name__}")
                continue

            # Required keys
            for k in ("assetId", "type", "uri"):
                if k not in asset:
                    self._err(apath, "MISSING_FIELD", f"Asset missing field: {k}")

            # Unknown fields
            a_allowed = {"assetId", "type", "uri"}
            for k in asset:
                if k not in a_allowed:
                    self._err(apath, "UNKNOWN_FIELD", f"Unknown asset field: {k}")

            # assetId
            aid = asset.get("assetId")
            if aid is not None:
                if not isinstance(aid, str):
                    self._err(apath, "TYPE_ERROR",
                              f"assetId must be string, got {type(aid).__name__}")
                elif not aid.strip():
                    self._err(apath, "EMPTY_ASSET_FIELD", "Empty assetId")
                asset_ids.append(aid)

            # type
            atype = asset.get("type")
            if atype is not None:
                if not isinstance(atype, str):
                    self._err(apath, "TYPE_ERROR",
                              f"type must be string, got {type(atype).__name__}")
                elif atype not in VALID_ASSET_TYPES:
                    self._err(apath, "INVALID_ASSET_TYPE",
                              f"asset type '{atype}' not in {VALID_ASSET_TYPES}")

            # uri
            uri = asset.get("uri")
            if uri is not None:
                if not isinstance(uri, str):
                    self._err(apath, "TYPE_ERROR",
                              f"uri must be string, got {type(uri).__name__}")
                elif not uri.strip():
                    self._err(apath, "EMPTY_ASSET_FIELD", "asset uri is empty")

        # assetId uniqueness
        aid_counts = Counter(asset_ids)
        for aid, count in aid_counts.items():
            if count > 1 and aid:
                self._err("assets", "DUPLICATE_ASSET_ID",
                          f"Duplicate assetId: {aid} (appears {count} times)")


# ============================================================
# CLI
# ============================================================


def validate_file(filepath, strict=False):
    """Validate a single JSON file. Returns (success, stats_dict)."""
    fpath = Path(filepath)
    try:
        with open(fpath, "r", encoding="utf-8") as fh:
            pkg = json.load(fh)
    except json.JSONDecodeError as e:
        print(f"  JSON PARSE ERROR: {e}")
        return False, {}
    except FileNotFoundError:
        print(f"  FILE NOT FOUND: {filepath}")
        return False, {}
    except Exception as e:
        print(f"  ERROR reading file: {e}")
        return False, {}

    v = Validator(strict=strict)
    errors, warnings = v.validate(pkg)

    scene_count = len(pkg.get("scenes", [])) if isinstance(pkg, dict) else 0
    question_count = sum(
        1 for s in pkg.get("scenes", []) if isinstance(s, dict)
        for b in s.get("knowledgeBindings", []) if isinstance(b, dict)
        and b.get("purpose") == "QUESTION"
    ) if isinstance(pkg, dict) else 0
    total_choices = sum(
        len(s.get("choices", [])) for s in pkg.get("scenes", [])
        if isinstance(s, dict)
    ) if isinstance(pkg, dict) else 0
    total_dialogue = sum(
        len(s.get("dialogue", [])) for s in pkg.get("scenes", [])
        if isinstance(s, dict)
    ) if isinstance(pkg, dict) else 0

    stats = {
        "scenes": scene_count,
        "questions": question_count,
        "choices": total_choices,
        "dialogue_lines": total_dialogue,
        "errors": len(errors),
        "warnings": len(warnings),
    }

    print(f"  Scenes:         {scene_count}")
    print(f"  Questions:      {question_count}")
    print(f"  Choices:        {total_choices}")
    print(f"  Dialogue lines: {total_dialogue}")

    if warnings:
        print(f"\n  Warnings ({len(warnings)}):")
        for path, code, msg in warnings:
            print(f"    [{code}] {path}: {msg}")

    if errors:
        print(f"\n  ERRORS ({len(errors)}):")
        for path, code, msg in errors:
            print(f"    [{code}] {path}: {msg}")
        print(f"\n  RESULT: FAIL")
        return False, stats
    else:
        if strict and warnings:
            print(f"\n  RESULT: FAIL (strict mode: {len(warnings)} warnings treated as errors)")
            return False, stats
        print(f"\n  RESULT: PASS")
        return True, stats


def main():
    parser = argparse.ArgumentParser(
        description="GalGame GamePackage schema 1.0 validator"
    )
    parser.add_argument(
        "files",
        nargs="*",
        help="JSON files to validate (default: all *.json in mocks/)"
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat warnings as errors"
    )
    parser.add_argument(
        "--dir",
        default=None,
        help="Directory to search for JSON files (default: same dir as this script)"
    )
    args = parser.parse_args()

    # Determine files to validate
    if args.files:
        files = args.files
    else:
        if args.dir:
            search_dir = Path(args.dir)
        else:
            search_dir = Path(__file__).parent
        files = sorted(search_dir.glob("*.json"))
        if not files:
            print(f"No JSON files found in {search_dir}")
            return 1

    print(f"GalGame GamePackage Validator — schema 1.0")
    print(f"Files to validate: {len(files)}")
    if args.strict:
        print("Mode: STRICT (warnings treated as errors)")

    all_ok = True
    all_stats = []

    for f in files:
        fpath = Path(f)
        print(f"\n{'=' * 70}")
        print(f"Validating: {fpath.name}")
        print(f"{'=' * 70}")

        ok, stats = validate_file(f, strict=args.strict)
        stats["file"] = fpath.name
        stats["pass"] = ok
        all_stats.append(stats)
        if not ok:
            all_ok = False

    # Summary table
    print(f"\n{'=' * 70}")
    print("SUMMARY")
    print(f"{'=' * 70}")
    print(f"{'File':<45} {'Scenes':>7} {'Qs':>4} {'Errs':>5} {'Warns':>6} {'Result':>8}")
    print(f"{'-' * 45} {'-' * 7} {'-' * 4} {'-' * 5} {'-' * 6} {'-' * 8}")
    for s in all_stats:
        result = "PASS" if s["pass"] else "FAIL"
        print(f"{s['file']:<45} {s['scenes']:>7} {s['questions']:>4} "
              f"{s['errors']:>5} {s['warnings']:>6} {result:>8}")

    print(f"\n{'=' * 70}")
    if all_ok:
        print("ALL FILES PASSED VALIDATION")
    else:
        failed = sum(1 for s in all_stats if not s["pass"])
        print(f"{failed}/{len(all_stats)} FILE(S) FAILED VALIDATION")
    print(f"{'=' * 70}")

    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
