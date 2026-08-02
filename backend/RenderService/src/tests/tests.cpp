// Native self-test suite for the RenderService runtime core. The Docker
// build compiles and runs this binary as an image gate; xmake host builds
// run it via `xmake run`. Everything is exercised through the same code
// paths the WASM reactor exports (including the extern "C" ABI itself).
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>
#include <vector>

#include "../core/json.hpp"
#include "../core/package.hpp"
#include "../core/runtime.hpp"

extern "C"
{
std::int32_t initialize(const char* configJson);
const char* loadPackage(const char* packageJson);
std::int32_t startSession(const char* sessionJson);
const char* dispatchInput(const char* inputJson);
void renderFrame(double deltaMs);
const char* serializeState();
const char* getLastError();
void dispose();
std::uint32_t rtAbiVersion();
const char* rtVersion();
}

namespace rt::tests
{
namespace
{

int g_checks = 0;
int g_failures = 0;

void check(bool ok, const char* label)
{
    ++g_checks;
    if (!ok)
    {
        ++g_failures;
        std::printf("[FAIL] %s\n", label);
    }
}

// --- fixtures --------------------------------------------------------------

constexpr const char* kTwoScenePackage = R"json({
  "schemaVersion": "1.0",
  "packageId": "f2561bb2-b88c-47ef-b0ae-8f283ff64f1b",
  "generatorVersion": "gala-0.1.0",
  "reviewPlanId": "8e812950-3311-40a7-93ab-636409df8cc2",
  "snapshotVersion": "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620",
  "entrySceneId": "scene-001",
  "scenes": [
    {
      "sceneId": "scene-001",
      "dialogue": [
        {"speakerId": "heroine", "text": "水稻分蘖期最关键的管理目标是什么？", "emotion": "curious"}
      ],
      "choices": [
        {"choiceId": "c-right", "questionId": "6428a20a-66dd-44c9-944f-d7b36fa9c95a",
         "text": "协调群体数量与个体生长", "nextSceneId": "scene-002", "scoreDelta": 1,
         "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb",
         "answerKind": "CHOICE", "correct": true},
        {"choiceId": "c-wrong", "questionId": "6428a20a-66dd-44c9-944f-d7b36fa9c95a",
         "text": "尽量提高种植密度", "nextSceneId": "scene-001", "scoreDelta": 0,
         "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb",
         "answerKind": "CHOICE", "correct": false}
      ],
      "knowledgeBindings": [
        {"knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb",
         "questionId": "6428a20a-66dd-44c9-944f-d7b36fa9c95a", "purpose": "QUESTION"}
      ]
    },
    {
      "sceneId": "scene-002",
      "dialogue": [{"speakerId": "heroine", "text": "回答正确，本轮复习完成！"}],
      "choices": [],
      "knowledgeBindings": []
    }
  ],
  "assets": []
})json";

constexpr const char* kSession = R"json({
  "sessionId": "bc98017d-cf5f-44fc-ac09-9604a2a0248b",
  "userId": "7bc4918a-9079-4ea2-9e8e-369ad79a9f20",
  "packageId": "f2561bb2-b88c-47ef-b0ae-8f283ff64f1b",
  "reviewPlanId": "8e812950-3311-40a7-93ab-636409df8cc2",
  "snapshotVersion": "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620",
  "status": "CREATED",
  "currentSceneId": null,
  "progressVersion": 0,
  "startedAt": null,
  "completedAt": null
})json";

// --- helpers ---------------------------------------------------------------

json::Value parseOk(const char* text, const char* label)
{
    json::ParseResult parsed = json::parse(std::string_view(text));
    check(parsed.ok, label);
    return parsed.value;
}

bool hasIssue(const pkg::ValidationResult& result, std::string_view path, std::string_view code)
{
    for (const pkg::ValidationIssue& issue : result.errors)
    {
        if (issue.path == path && issue.code == code)
        {
            return true;
        }
    }
    return false;
}

json::Value* mutableMember(json::Value& object, std::string_view key)
{
    for (auto& member : object.members())
    {
        if (member.first == key)
        {
            return &member.second;
        }
    }
    return nullptr;
}

json::Value& sceneAt(json::Value& package, std::size_t index)
{
    return mutableMember(package, "scenes")->items()[index];
}

std::string errorCode()
{
    const json::ParseResult parsed = json::parse(std::string_view(getLastError()));
    const json::Value* code = parsed.value.find("code");
    return parsed.ok && code != nullptr && code->isString() ? code->asString() : "<unparseable>";
}

json::Value parseEvents(const char* eventsJson, const char* label)
{
    json::ParseResult parsed = json::parse(std::string_view(eventsJson));
    check(parsed.ok && parsed.value.isArray(), label);
    return parsed.value;
}

bool eventTypeAt(const json::Value& events, std::size_t index, std::string_view type)
{
    if (!events.isArray() || index >= events.items().size())
    {
        return false;
    }
    const json::Value* value = events.items()[index].find("type");
    return value != nullptr && value->isString() && value->asString() == type;
}

double numberField(const json::Value& object, std::string_view key)
{
    const json::Value* value = object.find(key);
    return value != nullptr && value->isNumber() ? value->asNumber() : NAN;
}

std::string stringField(const json::Value& object, std::string_view key)
{
    const json::Value* value = object.find(key);
    return value != nullptr && value->isString() ? value->asString() : "<missing>";
}

// --- suites ----------------------------------------------------------------

void jsonSuite()
{
    check(parseOk("null", "json: null").isNull(), "json: null value");
    check(parseOk("true", "json: true").asBoolean(), "json: true value");
    check(parseOk("-0.5", "json: number").asNumber() == -0.5, "json: number value");
    check(parseOk("12e3", "json: exponent").asNumber() == 12000.0, "json: exponent value");
    check(parseOk(R"("aAé中")", "json: escapes").asString() == "aAé中",
          "json: unicode escape value");
    check(parseOk(R"("😀")", "json: surrogate pair").asString() == "\U0001F600",
          "json: surrogate pair value");
    check(parseOk(R"("\n\t\"\\\/")", "json: simple escapes").asString() == "\n\t\"\\/",
          "json: simple escape value");

    const char* rejected[] = {
        "{", "[1,]", "01", "1.", ".5", "+1", "nul", "\"abc", R"("\x")", R"("\ud800")",
        "{} x", "\"a\x01\"",
    };
    for (const char* bad : rejected)
    {
        check(!json::parse(std::string_view(bad)).ok, "json: rejects malformed input");
    }
    std::string bomb(200, '[');
    check(!json::parse(bomb).ok, "json: rejects depth bomb");

    const json::Value dup = parseOk(R"({"a":1,"a":2})", "json: duplicate keys parse");
    check(dup.find("a") != nullptr && dup.find("a")->asNumber() == 2.0,
          "json: duplicate keys resolve to the last value");

    json::Value object = json::Value::object();
    object.set("b", json::Value::number(1.0));
    object.set("a", json::Value::string("x\ny"));
    object.set("z", json::Value::number(0.5));
    check(json::serialize(object) == R"({"b":1,"a":"x\ny","z":0.5})",
          "json: serialize keeps insertion order and escapes");
    check(json::serialize(json::Value::number(-0.0)) == "0", "json: -0 serializes as 0");

    const json::Value overflow = parseOk("1e309", "json: overflow parse");
    check(std::isinf(overflow.asNumber()), "json: overflow becomes Infinity");
    check(json::serialize(overflow) == "null", "json: Infinity serializes as null");
    check(parseOk("1e-400", "json: underflow parse").asNumber() == 0.0,
          "json: underflow becomes zero");
}

void uuidSuite()
{
    check(pkg::isUuidV4("6428a20a-66dd-44c9-944f-d7b36fa9c95a"), "uuid: valid v4");
    check(!pkg::isUuidV4("6428A20A-66DD-44C9-944F-D7B36FA9C95A"), "uuid: uppercase rejected");
    check(!pkg::isUuidV4("c3bd304f-dc44-df55-8608-64c20672e90a"), "uuid: version nibble enforced");
    check(!pkg::isUuidV4("6428a20a-66dd-44c9-c44f-d7b36fa9c95a"), "uuid: variant nibble enforced");
    check(!pkg::isUuidV4("6428a20a-66dd-44c9-944f-d7b36fa9c95"), "uuid: length enforced");
}

void validatorSuite()
{
    const json::Value golden = parseOk(kTwoScenePackage, "validator: fixture parses");
    check(pkg::validate(golden).valid, "validator: golden fixture is valid");

    {
        const pkg::ValidationResult result = pkg::validate(parseOk("[]", "validator: array root"));
        check(hasIssue(result, "$", "PACKAGE_REQUIRED"), "validator: non-object root");
    }
    {
        json::Value doc = golden;
        *mutableMember(doc, "schemaVersion") = json::Value::string("2.0");
        check(hasIssue(pkg::validate(doc), "$.schemaVersion", "SCHEMA_UNSUPPORTED"),
              "validator: schema version");
    }
    {
        json::Value doc = golden;
        *mutableMember(doc, "packageId") = json::Value::string("F2561BB2-B88C-47EF-B0AE-8F283FF64F1B");
        check(hasIssue(pkg::validate(doc), "$.packageId", "UUID_V4_REQUIRED"),
              "validator: uppercase packageId rejected");
    }
    {
        json::Value doc = golden;
        *mutableMember(doc, "scenes") = json::Value::null();
        const pkg::ValidationResult result = pkg::validate(doc);
        check(hasIssue(result, "$.scenes", "SCENE_COUNT_OUT_OF_RANGE"),
              "validator: scenes required");
        check(!hasIssue(result, "$.assets", "FIELD_REQUIRED"),
              "validator: early return before assets (adapter parity)");
    }
    {
        json::Value doc = golden;
        *mutableMember(sceneAt(doc, 1), "sceneId") = json::Value::string("scene-001");
        check(hasIssue(pkg::validate(doc), "$.scenes[1].sceneId", "SCENE_ID_INVALID"),
              "validator: duplicate sceneId");
    }
    {
        json::Value doc = golden;
        *mutableMember(sceneAt(doc, 1), "dialogue") = json::Value::array();
        check(hasIssue(pkg::validate(doc), "$.scenes[1].dialogue", "DIALOGUE_COUNT_OUT_OF_RANGE"),
              "validator: empty dialogue");
    }
    {
        json::Value doc = golden;
        json::Value line = json::Value::object();
        line.set("speakerId", json::Value::string("　"));
        line.set("text", json::Value::string("ok"));
        mutableMember(sceneAt(doc, 1), "dialogue")->items()[0] = std::move(line);
        check(hasIssue(pkg::validate(doc), "$.scenes[1].dialogue[0]", "DIALOGUE_INVALID"),
              "validator: ideographic-space speaker counts as blank (JS trim parity)");
    }
    {
        json::Value doc = golden;
        json::Value& choices = *mutableMember(sceneAt(doc, 0), "choices");
        const json::Value original = choices.items()[0];
        while (choices.items().size() < 7)
        {
            json::Value clone = original;
            *mutableMember(clone, "choiceId") =
                json::Value::string("c-extra-" + std::to_string(choices.items().size()));
            choices.push(std::move(clone));
        }
        check(hasIssue(pkg::validate(doc), "$.scenes[0].choices", "CHOICE_COUNT_OUT_OF_RANGE"),
              "validator: more than six choices");
    }
    {
        json::Value doc = golden;
        json::Value& choices = *mutableMember(sceneAt(doc, 0), "choices");
        *mutableMember(choices.items()[1], "choiceId") = json::Value::string("c-right");
        check(hasIssue(pkg::validate(doc), "$.scenes[0].choices[1].choiceId", "CHOICE_ID_INVALID"),
              "validator: duplicate choiceId in scene");
    }
    {
        json::Value doc = golden;
        json::Value& choice = mutableMember(sceneAt(doc, 0), "choices")->items()[0];
        *mutableMember(choice, "scoreDelta") = json::Value::string("1");
        check(hasIssue(pkg::validate(doc), "$.scenes[0].choices[0].scoreDelta", "NUMBER_REQUIRED"),
              "validator: scoreDelta must be a number");
    }
    {
        json::Value doc = golden;
        json::Value& choice = mutableMember(sceneAt(doc, 0), "choices")->items()[0];
        json::Value replacement = json::Value::object();
        for (const auto& member : choice.members())
        {
            if (member.first != "nextSceneId")
            {
                replacement.set(member.first, member.second);
            }
        }
        choice = std::move(replacement);
        check(hasIssue(pkg::validate(doc), "$.scenes[0].choices[0].nextSceneId",
                       "SCENE_REFERENCE_INVALID"),
              "validator: absent nextSceneId rejected (undefined !== null parity)");
    }
    {
        json::Value doc = golden;
        json::Value& choice = mutableMember(sceneAt(doc, 0), "choices")->items()[0];
        *mutableMember(choice, "nextSceneId") = json::Value::string("scene-ghost");
        check(hasIssue(pkg::validate(doc), "$.scenes[0].choices[0].nextSceneId",
                       "SCENE_REFERENCE_INVALID"),
              "validator: dangling nextSceneId");
    }
    {
        json::Value doc = golden;
        json::Value& binding = mutableMember(sceneAt(doc, 0), "knowledgeBindings")->items()[0];
        *mutableMember(binding, "purpose") = json::Value::string("QUIZ");
        check(hasIssue(pkg::validate(doc), "$.scenes[0].knowledgeBindings[0].purpose",
                       "PURPOSE_INVALID"),
              "validator: unknown purpose");
    }
    {
        json::Value doc = golden;
        json::Value& bindings = *mutableMember(sceneAt(doc, 1), "knowledgeBindings");
        json::Value binding = json::Value::object();
        binding.set("knowledgePointId",
                    json::Value::string("d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"));
        binding.set("purpose", json::Value::string("EXPLAIN"));
        bindings.push(std::move(binding));
        check(hasIssue(pkg::validate(doc), "$.scenes[1].knowledgeBindings[0].questionId",
                       "UUID_V4_REQUIRED"),
              "validator: binding questionId must be explicit null or UUID v4");
    }
    {
        json::Value doc = golden;
        json::Value& bindings = *mutableMember(sceneAt(doc, 0), "knowledgeBindings");
        bindings.push(bindings.items()[0]);
        const pkg::ValidationResult result = pkg::validate(doc);
        check(hasIssue(result, "$.scenes[0].knowledgeBindings", "QUESTION_BINDING_COUNT"),
              "validator: at most one QUESTION binding per scene");
        check(hasIssue(result, "$.scenes[0].choices", "SCORING_WITHOUT_QUESTION"),
              "validator: >1 bindings also trip the no-question branch (JS parity)");
    }
    {
        json::Value doc = golden;
        json::Value& choices = *mutableMember(sceneAt(doc, 0), "choices");
        *mutableMember(choices.items()[0], "correct") = json::Value::boolean(false);
        check(hasIssue(pkg::validate(doc), "$.scenes[0].choices", "QUESTION_CHOICES_INVALID"),
              "validator: question needs a correct choice");
    }
    {
        json::Value doc = golden;
        json::Value& choice = mutableMember(sceneAt(doc, 0), "choices")->items()[0];
        json::Value replacement = json::Value::object();
        for (const auto& member : choice.members())
        {
            if (member.first != "answerKind")
            {
                replacement.set(member.first, member.second);
            }
        }
        choice = std::move(replacement);
        check(hasIssue(pkg::validate(doc), "$.scenes[0].choices", "QUESTION_BINDING_MISMATCH"),
              "validator: question choices must carry answerKind CHOICE");
    }
    {
        json::Value doc = golden;
        json::Value& scene = sceneAt(doc, 1);
        json::Value choice = json::Value::object();
        choice.set("choiceId", json::Value::string("c-end"));
        choice.set("questionId", json::Value::string("36924035-ec0a-46aa-aa7e-25b86edfa259"));
        choice.set("text", json::Value::string("结束"));
        choice.set("nextSceneId", json::Value::null());
        choice.set("scoreDelta", json::Value::number(0.0));
        choice.set("knowledgePointId",
                   json::Value::string("d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"));
        choice.set("correct", json::Value::boolean(false));
        mutableMember(scene, "choices")->push(std::move(choice));
        check(hasIssue(pkg::validate(doc), "$.scenes[1].choices", "SCORING_WITHOUT_QUESTION"),
              "validator: non-question scene cannot carry correct");
    }
    {
        json::Value doc = golden;
        *mutableMember(doc, "entrySceneId") = json::Value::string("scene-ghost");
        check(hasIssue(pkg::validate(doc), "$.entrySceneId", "ENTRY_SCENE_INVALID"),
              "validator: entry scene must exist");
    }
    {
        // Point every path away from scene-001 so the QUESTION scene becomes
        // unreachable: entry moves to scene-002 (terminal).
        json::Value doc = golden;
        *mutableMember(doc, "entrySceneId") = json::Value::string("scene-002");
        check(hasIssue(pkg::validate(doc), "$.scenes", "UNREACHABLE_QUESTION_SCENE"),
              "validator: unreachable question scene");
    }
    {
        json::Value doc = golden;
        json::Value asset = json::Value::object();
        asset.set("assetId", json::Value::string("bg-1"));
        asset.set("type", json::Value::string("VIDEO"));
        asset.set("uri", json::Value::string("/assets/bg-1.png"));
        mutableMember(doc, "assets")->push(std::move(asset));
        check(hasIssue(pkg::validate(doc), "$.assets[0]", "ASSET_INVALID"),
              "validator: unsupported asset type");
    }
}

void runtimeSuite()
{
    dispose();
    check(errorCode() == "NO_ERROR", "runtime: NO_ERROR after dispose");

    const char* beforeInit = loadPackage(kTwoScenePackage);
    {
        const json::Value result = parseOk(beforeInit, "runtime: pre-init result parses");
        const json::Value* valid = result.find("valid");
        check(valid != nullptr && valid->isBoolean() && !valid->asBoolean(),
              "runtime: loadPackage before initialize fails");
        check(errorCode() == "RUNTIME_NOT_INITIALIZED", "runtime: pre-init error code");
    }

    check(initialize("not json") == 1 && errorCode() == "JSON_PARSE_ERROR",
          "runtime: initialize rejects malformed config");
    check(initialize("[]") == 1 && errorCode() == "CONFIG_INVALID",
          "runtime: initialize rejects non-object config");
    check(initialize(nullptr) == 1, "runtime: initialize rejects null config");
    check(initialize("{}") == 0 && errorCode() == "NO_ERROR", "runtime: initialize succeeds");

    check(startSession(kSession) == 1 && errorCode() == "PACKAGE_NOT_LOADED",
          "runtime: startSession requires a package");

    {
        const json::Value result =
            parseOk(loadPackage(kTwoScenePackage), "runtime: package result parses");
        const json::Value* valid = result.find("valid");
        check(valid != nullptr && valid->asBoolean(), "runtime: package loads");
    }
    {
        // An invalid follow-up load keeps the previous package usable.
        const json::Value result =
            parseOk(loadPackage("{\"schemaVersion\":\"2.0\"}"), "runtime: bad package parses");
        const json::Value* valid = result.find("valid");
        check(valid != nullptr && !valid->asBoolean(), "runtime: bad package rejected");
        check(errorCode() == "PACKAGE_INVALID", "runtime: bad package error code");
    }

    check(startSession("{\"sessionId\":\"nope\"}") == 1 && errorCode() == "SESSION_JSON_INVALID",
          "runtime: session id validated");
    {
        std::string mismatch(kSession);
        const std::string needle = "f2561bb2-b88c-47ef-b0ae-8f283ff64f1b";
        mismatch.replace(mismatch.find(needle), needle.size(),
                         "00000000-0000-4000-8000-000000000000");
        check(startSession(mismatch.c_str()) == 1 && errorCode() == "SESSION_PACKAGE_MISMATCH",
              "runtime: package mismatch rejected");
    }
    {
        std::string wrongStatus(kSession);
        const std::string needle = "\"CREATED\"";
        wrongStatus.replace(wrongStatus.find(needle), needle.size(), "\"COMPLETED\"");
        check(startSession(wrongStatus.c_str()) == 1 && errorCode() == "SESSION_STATUS_INVALID",
              "runtime: closed session cannot start");
    }
    {
        std::string wrongScene(kSession);
        const std::string needle = "\"currentSceneId\": null";
        wrongScene.replace(wrongScene.find(needle), needle.size(),
                           "\"currentSceneId\": \"scene-ghost\"");
        check(startSession(wrongScene.c_str()) == 1 && errorCode() == "SESSION_SCENE_UNKNOWN",
              "runtime: unknown resume scene rejected");
    }

    check(startSession(kSession) == 0, "runtime: session starts");
    {
        const json::Value state = parseOk(serializeState(), "runtime: initial state parses");
        check(stringField(state, "status") == "RUNNING", "runtime: initial status RUNNING");
        check(stringField(state, "currentSceneId") == "scene-001", "runtime: entry scene current");
        check(stringField(state, "schemaVersion") == kStateSchemaVersion,
              "runtime: state schema version");
        check(numberField(state, "score") == 0.0, "runtime: initial score 0");
        const json::Value* visited = state.find("visitedSceneIds");
        check(visited != nullptr && visited->isArray() && visited->items().size() == 1,
              "runtime: initial visited list");
    }

    check(std::string_view(dispatchInput("{\"type\":\"ADVANCE\"}")) == "[]"
              && errorCode() == "INPUT_CHOICE_REQUIRED",
          "runtime: ADVANCE requires choice-free scene");
    check(std::string_view(dispatchInput("{\"type\":\"CHOICE_SELECTED\",\"choiceId\":\"c-x\"}"))
              == "[]"
              && errorCode() == "INPUT_CHOICE_UNKNOWN",
          "runtime: unknown choice rejected");
    check(std::string_view(dispatchInput("{\"type\":\"SKIP\"}")) == "[]"
              && errorCode() == "INPUT_TYPE_UNSUPPORTED",
          "runtime: unsupported input type");
    check(std::string_view(
              dispatchInput("{\"type\":\"CHOICE_SELECTED\",\"choiceId\":\"c-right\","
                            "\"attemptId\":\"UPPER\"}"))
              == "[]"
              && errorCode() == "INPUT_JSON_INVALID",
          "runtime: invalid attemptId rejected");

    renderFrame(16.5);
    renderFrame(16.5);

    {
        // Wrong answer first: attempt 1, self-loop back to scene-001.
        const json::Value events = parseEvents(
            dispatchInput("{\"type\":\"CHOICE_SELECTED\",\"choiceId\":\"c-wrong\"}"),
            "runtime: wrong-answer events parse");
        check(events.items().size() == 2, "runtime: wrong answer emits two events");
        check(eventTypeAt(events, 0, "ANSWER_RECORDED"), "runtime: wrong answer recorded");
        check(eventTypeAt(events, 1, "SCENE_ENTERED"), "runtime: wrong answer self-loop");
        check(numberField(events.items()[0], "attemptNumber") == 1.0, "runtime: attempt 1");
        const json::Value* correct = events.items()[0].find("correct");
        check(correct != nullptr && correct->isBoolean() && !correct->asBoolean(),
              "runtime: wrong answer marked incorrect");
    }
    {
        const json::Value events = parseEvents(
            dispatchInput("{\"type\":\"CHOICE_SELECTED\",\"choiceId\":\"c-right\","
                          "\"attemptId\":\"36924035-ec0a-46aa-aa7e-25b86edfa259\","
                          "\"occurredAt\":\"2026-08-02T09:01:40Z\"}"),
            "runtime: right-answer events parse");
        check(events.items().size() == 2, "runtime: right answer emits two events");
        check(eventTypeAt(events, 0, "ANSWER_RECORDED") && eventTypeAt(events, 1, "SCENE_ENTERED"),
              "runtime: right answer event order");
        check(numberField(events.items()[0], "attemptNumber") == 2.0, "runtime: attempt 2");
        check(stringField(events.items()[1], "sceneId") == "scene-002",
              "runtime: transition to scene-002");
    }
    {
        const json::Value state = parseOk(serializeState(), "runtime: mid state parses");
        check(numberField(state, "score") == 1.0, "runtime: score accumulates");
        check(numberField(state, "elapsedMs") == 33.0, "runtime: elapsed accumulates");
        const json::Value* answers = state.find("answers");
        check(answers != nullptr && answers->isArray() && answers->items().size() == 2,
              "runtime: two attempts recorded");
        const json::Value& second = answers->items()[1];
        check(stringField(second, "attemptId") == "36924035-ec0a-46aa-aa7e-25b86edfa259",
              "runtime: attemptId passthrough");
        check(stringField(second, "occurredAt") == "2026-08-02T09:01:40Z",
              "runtime: occurredAt passthrough");
        const json::Value* firstAttemptId = answers->items()[0].find("attemptId");
        check(firstAttemptId != nullptr && firstAttemptId->isNull(),
              "runtime: absent attemptId stays null");
    }
    {
        const json::Value events =
            parseEvents(dispatchInput("{\"type\":\"ADVANCE\"}"), "runtime: completion parses");
        check(events.items().size() == 1 && eventTypeAt(events, 0, "SESSION_COMPLETED"),
              "runtime: terminal ADVANCE completes");
        check(numberField(events.items()[0], "answeredQuestionCount") == 1.0,
              "runtime: distinct questions counted");
        check(numberField(events.items()[0], "attemptCount") == 2.0, "runtime: attempts counted");
        check(numberField(events.items()[0], "visitedSceneCount") == 2.0,
              "runtime: visited scenes counted");
    }
    check(std::string_view(dispatchInput("{\"type\":\"ADVANCE\"}")) == "[]"
              && errorCode() == "SESSION_ALREADY_COMPLETED",
          "runtime: completed session rejects input");
    renderFrame(100.0);
    {
        const json::Value state = parseOk(serializeState(), "runtime: final state parses");
        check(stringField(state, "status") == "COMPLETED", "runtime: final status COMPLETED");
        check(numberField(state, "elapsedMs") == 33.0,
              "runtime: elapsed frozen after completion");
    }

    check(startSession(kSession) == 0, "runtime: restart allowed");
    {
        const json::Value state = parseOk(serializeState(), "runtime: restarted state parses");
        check(stringField(state, "status") == "RUNNING" && numberField(state, "score") == 0.0,
              "runtime: restart resets progress");
    }

    dispose();
    check(std::string_view(serializeState()) == "null" && errorCode() == "RUNTIME_NOT_INITIALIZED",
          "runtime: dispose resets the runtime");

    check(rtAbiVersion() == kAbiVersion, "abi: version constant");
    check(std::string_view(rtVersion()) == kRuntimeVersion, "abi: runtime version string");
}

} // namespace

int runAll()
{
    jsonSuite();
    uuidSuite();
    validatorSuite();
    runtimeSuite();
    std::printf("render-core self-test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}

} // namespace rt::tests
