#include "runtime.hpp"

#include <algorithm>
#include <cmath>

namespace rt
{
namespace
{

bool isBlank(std::string_view text)
{
    for (const char c : text)
    {
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r')
        {
            return false;
        }
    }
    return true;
}

const json::Value* member(const json::Value& object, std::string_view key)
{
    return object.isObject() ? object.find(key) : nullptr;
}

bool memberAbsentOrNull(const json::Value& object, std::string_view key)
{
    const json::Value* value = member(object, key);
    return value == nullptr || value->isNull();
}

} // namespace

void Runtime::reset()
{
    initialized_ = false;
    packageLoaded_ = false;
    package_ = pkg::Package{};
    sessionActive_ = false;
    completed_ = false;
    sessionId_.clear();
    userId_.clear();
    currentSceneId_.clear();
    visitedSceneIds_.clear();
    score_ = 0.0;
    elapsedMs_ = 0.0;
    answers_.clear();
    errorCode_ = "NO_ERROR";
    errorMessage_.clear();
}

void Runtime::setError(std::string code, std::string message)
{
    errorCode_ = std::move(code);
    errorMessage_ = std::move(message);
}

void Runtime::clearError()
{
    errorCode_ = "NO_ERROR";
    errorMessage_.clear();
}

const pkg::Scene* Runtime::currentScene() const
{
    return package_.findScene(currentSceneId_);
}

bool Runtime::initialize(std::string_view configJson)
{
    reset();
    const json::ParseResult parsed = json::parse(configJson);
    if (!parsed.ok)
    {
        setError("JSON_PARSE_ERROR", "config is not valid JSON: " + parsed.error);
        return false;
    }
    if (!parsed.value.isObject())
    {
        setError("CONFIG_INVALID", "config must be a JSON object");
        return false;
    }
    // RuntimeConfig v1 has no required members; unknown members are ignored
    // so the adapter can add hints without an ABI version bump.
    initialized_ = true;
    clearError();
    return true;
}

std::string Runtime::loadPackage(std::string_view packageJson)
{
    pkg::ValidationResult result;
    if (!initialized_)
    {
        setError("RUNTIME_NOT_INITIALIZED", "initialize must succeed before loadPackage");
        result.errors.push_back(pkg::ValidationIssue{
            "$", "RUNTIME_NOT_INITIALIZED", "initialize must succeed before loadPackage"});
        return json::serialize(result.toJson());
    }

    const json::ParseResult parsed = json::parse(packageJson);
    if (!parsed.ok)
    {
        setError("JSON_PARSE_ERROR", "gamePackage is not valid JSON: " + parsed.error);
        result.errors.push_back(pkg::ValidationIssue{
            "$", "JSON_PARSE_ERROR", "gamePackage is not valid JSON: " + parsed.error});
        return json::serialize(result.toJson());
    }

    result = pkg::validate(parsed.value);
    if (result.valid)
    {
        package_ = pkg::build(parsed.value);
        packageLoaded_ = true;
        // A new authoritative package invalidates any session started on the
        // previous one.
        sessionActive_ = false;
        completed_ = false;
        clearError();
    }
    else
    {
        const std::string firstCode = result.errors.empty() ? "UNKNOWN" : result.errors[0].code;
        setError("PACKAGE_INVALID", "game package failed validation: " + firstCode);
    }
    return json::serialize(result.toJson());
}

bool Runtime::startSession(std::string_view sessionJson)
{
    if (!initialized_)
    {
        setError("RUNTIME_NOT_INITIALIZED", "initialize must succeed before startSession");
        return false;
    }
    if (!packageLoaded_)
    {
        setError("PACKAGE_NOT_LOADED", "loadPackage must succeed before startSession");
        return false;
    }

    const json::ParseResult parsed = json::parse(sessionJson);
    if (!parsed.ok)
    {
        setError("JSON_PARSE_ERROR", "session is not valid JSON: " + parsed.error);
        return false;
    }
    const json::Value& session = parsed.value;
    if (!session.isObject())
    {
        setError("SESSION_JSON_INVALID", "session must be a JSON object");
        return false;
    }

    const json::Value* sessionId = member(session, "sessionId");
    if (sessionId == nullptr || !sessionId->isString() || !pkg::isUuidV4(sessionId->asString()))
    {
        setError("SESSION_JSON_INVALID", "sessionId must be a lowercase UUID v4");
        return false;
    }
    const json::Value* userId = member(session, "userId");
    if (userId == nullptr || !userId->isString() || !pkg::isUuidV4(userId->asString()))
    {
        setError("SESSION_JSON_INVALID", "userId must be a lowercase UUID v4");
        return false;
    }

    const auto matches = [&session, this](std::string_view key, const std::string& expected) {
        const json::Value* value = member(session, key);
        return value != nullptr && value->isString() && value->asString() == expected;
    };
    if (!matches("packageId", package_.packageId)
        || !matches("reviewPlanId", package_.reviewPlanId)
        || !matches("snapshotVersion", package_.snapshotVersion))
    {
        setError("SESSION_PACKAGE_MISMATCH",
                 "ReviewSession packageId/reviewPlanId/snapshotVersion do not match the loaded "
                 "package");
        return false;
    }

    if (!memberAbsentOrNull(session, "status"))
    {
        const json::Value* status = member(session, "status");
        if (!status->isString()
            || (status->asString() != "CREATED" && status->asString() != "RUNNING"))
        {
            setError("SESSION_STATUS_INVALID",
                     "a session can only start from status CREATED or RUNNING");
            return false;
        }
    }

    std::string startSceneId = package_.entrySceneId;
    if (!memberAbsentOrNull(session, "currentSceneId"))
    {
        const json::Value* currentSceneId = member(session, "currentSceneId");
        if (!currentSceneId->isString())
        {
            setError("SESSION_JSON_INVALID", "currentSceneId must be null or a string");
            return false;
        }
        if (package_.findScene(currentSceneId->asString()) == nullptr)
        {
            setError("SESSION_SCENE_UNKNOWN",
                     "currentSceneId does not reference a scene of the loaded package");
            return false;
        }
        startSceneId = currentSceneId->asString();
    }

    sessionActive_ = true;
    completed_ = false;
    sessionId_ = sessionId->asString();
    userId_ = userId->asString();
    currentSceneId_ = startSceneId;
    visitedSceneIds_.assign(1, startSceneId);
    score_ = 0.0;
    elapsedMs_ = 0.0;
    answers_.clear();
    clearError();
    return true;
}

json::Value Runtime::sessionCompletedEvent() const
{
    std::vector<std::string> distinctQuestionIds;
    for (const AnswerRecord& answer : answers_)
    {
        if (std::find(distinctQuestionIds.begin(), distinctQuestionIds.end(), answer.questionId)
            == distinctQuestionIds.end())
        {
            distinctQuestionIds.push_back(answer.questionId);
        }
    }
    json::Value event = json::Value::object();
    event.set("type", json::Value::string("SESSION_COMPLETED"));
    event.set("score", json::Value::number(score_));
    event.set("answeredQuestionCount",
              json::Value::number(static_cast<double>(distinctQuestionIds.size())));
    event.set("attemptCount", json::Value::number(static_cast<double>(answers_.size())));
    event.set("visitedSceneCount",
              json::Value::number(static_cast<double>(visitedSceneIds_.size())));
    event.set("elapsedMs", json::Value::number(elapsedMs_));
    return event;
}

std::string Runtime::dispatchInput(std::string_view inputJson)
{
    static constexpr const char* kNoEvents = "[]";
    if (!initialized_)
    {
        setError("RUNTIME_NOT_INITIALIZED", "initialize must succeed before dispatchInput");
        return kNoEvents;
    }
    if (!packageLoaded_)
    {
        setError("PACKAGE_NOT_LOADED", "loadPackage must succeed before dispatchInput");
        return kNoEvents;
    }
    if (!sessionActive_)
    {
        setError("SESSION_NOT_STARTED", "startSession must succeed before dispatchInput");
        return kNoEvents;
    }
    if (completed_)
    {
        setError("SESSION_ALREADY_COMPLETED", "the session has already completed");
        return kNoEvents;
    }

    const json::ParseResult parsed = json::parse(inputJson);
    if (!parsed.ok)
    {
        setError("JSON_PARSE_ERROR", "input is not valid JSON: " + parsed.error);
        return kNoEvents;
    }
    const json::Value& input = parsed.value;
    if (!input.isObject())
    {
        setError("INPUT_JSON_INVALID", "input must be a JSON object");
        return kNoEvents;
    }
    const json::Value* type = member(input, "type");
    if (type == nullptr || !type->isString())
    {
        setError("INPUT_JSON_INVALID", "input.type must be a string");
        return kNoEvents;
    }

    const pkg::Scene* scene = currentScene();
    if (scene == nullptr)
    {
        // Unreachable for validated packages; guards against internal drift.
        setError("SESSION_SCENE_UNKNOWN", "current scene is missing from the loaded package");
        return kNoEvents;
    }

    json::Value events = json::Value::array();

    if (type->asString() == "ADVANCE")
    {
        if (!scene->choices.empty())
        {
            setError("INPUT_CHOICE_REQUIRED", "the current scene requires selecting a choice");
            return kNoEvents;
        }
        completed_ = true;
        events.push(sessionCompletedEvent());
        clearError();
        return json::serialize(events);
    }

    if (type->asString() != "CHOICE_SELECTED")
    {
        setError("INPUT_TYPE_UNSUPPORTED",
                 "RuntimeInput v1 supports type CHOICE_SELECTED or ADVANCE");
        return kNoEvents;
    }

    const json::Value* choiceId = member(input, "choiceId");
    if (choiceId == nullptr || !choiceId->isString() || choiceId->asString().empty())
    {
        setError("INPUT_JSON_INVALID", "choiceId must be a non-empty string");
        return kNoEvents;
    }
    const pkg::Choice* choice = scene->findChoice(choiceId->asString());
    if (choice == nullptr)
    {
        setError("INPUT_CHOICE_UNKNOWN", "choiceId does not exist in the current scene");
        return kNoEvents;
    }

    bool hasAttemptId = false;
    std::string attemptId;
    if (!memberAbsentOrNull(input, "attemptId"))
    {
        const json::Value* value = member(input, "attemptId");
        if (!value->isString() || !pkg::isUuidV4(value->asString()))
        {
            setError("INPUT_JSON_INVALID", "attemptId must be null or a lowercase UUID v4");
            return kNoEvents;
        }
        hasAttemptId = true;
        attemptId = value->asString();
    }
    bool hasOccurredAt = false;
    std::string occurredAt;
    if (!memberAbsentOrNull(input, "occurredAt"))
    {
        const json::Value* value = member(input, "occurredAt");
        if (!value->isString() || isBlank(value->asString()))
        {
            setError("INPUT_JSON_INVALID", "occurredAt must be null or a non-blank string");
            return kNoEvents;
        }
        hasOccurredAt = true;
        occurredAt = value->asString();
    }

    if (scene->hasQuestion)
    {
        int attemptNumber = 1;
        for (const AnswerRecord& answer : answers_)
        {
            if (answer.questionId == scene->questionId)
            {
                ++attemptNumber;
            }
        }
        AnswerRecord record;
        record.sceneId = scene->sceneId;
        record.questionId = scene->questionId;
        record.knowledgePointId = scene->questionPointId;
        record.choiceId = choice->choiceId;
        record.correct = choice->hasCorrect && choice->correct;
        record.scoreDelta = choice->scoreDelta;
        record.attemptNumber = attemptNumber;
        record.hasAttemptId = hasAttemptId;
        record.attemptId = attemptId;
        record.hasOccurredAt = hasOccurredAt;
        record.occurredAt = occurredAt;
        answers_.push_back(record);

        json::Value event = json::Value::object();
        event.set("type", json::Value::string("ANSWER_RECORDED"));
        event.set("sceneId", json::Value::string(record.sceneId));
        event.set("questionId", json::Value::string(record.questionId));
        event.set("knowledgePointId", json::Value::string(record.knowledgePointId));
        event.set("choiceId", json::Value::string(record.choiceId));
        event.set("correct", json::Value::boolean(record.correct));
        event.set("scoreDelta", json::Value::number(record.scoreDelta));
        event.set("attemptNumber", json::Value::number(record.attemptNumber));
        events.push(std::move(event));
    }

    score_ += choice->scoreDelta;

    if (choice->hasNextScene)
    {
        currentSceneId_ = choice->nextSceneId;
        if (std::find(visitedSceneIds_.begin(), visitedSceneIds_.end(), currentSceneId_)
            == visitedSceneIds_.end())
        {
            visitedSceneIds_.push_back(currentSceneId_);
        }
        json::Value event = json::Value::object();
        event.set("type", json::Value::string("SCENE_ENTERED"));
        event.set("sceneId", json::Value::string(currentSceneId_));
        events.push(std::move(event));
    }
    else
    {
        completed_ = true;
        events.push(sessionCompletedEvent());
    }

    clearError();
    return json::serialize(events);
}

void Runtime::renderFrame(double deltaMs)
{
    if (sessionActive_ && !completed_ && std::isfinite(deltaMs) && deltaMs > 0.0)
    {
        elapsedMs_ += deltaMs;
    }
}

std::string Runtime::serializeState()
{
    if (!initialized_)
    {
        setError("RUNTIME_NOT_INITIALIZED", "initialize must succeed before serializeState");
        return "null";
    }
    if (!packageLoaded_)
    {
        setError("PACKAGE_NOT_LOADED", "loadPackage must succeed before serializeState");
        return "null";
    }
    if (!sessionActive_)
    {
        setError("SESSION_NOT_STARTED", "startSession must succeed before serializeState");
        return "null";
    }

    json::Value state = json::Value::object();
    state.set("schemaVersion", json::Value::string(kStateSchemaVersion));
    state.set("runtimeVersion", json::Value::string(kRuntimeVersion));
    state.set("abiVersion", json::Value::number(static_cast<double>(kAbiVersion)));
    state.set("sessionId", json::Value::string(sessionId_));
    state.set("userId", json::Value::string(userId_));
    state.set("packageId", json::Value::string(package_.packageId));
    state.set("reviewPlanId", json::Value::string(package_.reviewPlanId));
    state.set("snapshotVersion", json::Value::string(package_.snapshotVersion));
    state.set("status", json::Value::string(completed_ ? "COMPLETED" : "RUNNING"));
    state.set("currentSceneId", json::Value::string(currentSceneId_));

    json::Value visited = json::Value::array();
    for (const std::string& sceneId : visitedSceneIds_)
    {
        visited.push(json::Value::string(sceneId));
    }
    state.set("visitedSceneIds", std::move(visited));
    state.set("score", json::Value::number(score_));
    state.set("elapsedMs", json::Value::number(elapsedMs_));

    json::Value answers = json::Value::array();
    for (const AnswerRecord& record : answers_)
    {
        json::Value entry = json::Value::object();
        entry.set("sceneId", json::Value::string(record.sceneId));
        entry.set("questionId", json::Value::string(record.questionId));
        entry.set("knowledgePointId", json::Value::string(record.knowledgePointId));
        entry.set("choiceId", json::Value::string(record.choiceId));
        entry.set("answerKind", json::Value::string("CHOICE"));
        entry.set("correct", json::Value::boolean(record.correct));
        entry.set("scoreDelta", json::Value::number(record.scoreDelta));
        entry.set("attemptNumber", json::Value::number(record.attemptNumber));
        entry.set("attemptId", record.hasAttemptId ? json::Value::string(record.attemptId)
                                                   : json::Value::null());
        entry.set("occurredAt", record.hasOccurredAt ? json::Value::string(record.occurredAt)
                                                     : json::Value::null());
        answers.push(std::move(entry));
    }
    state.set("answers", std::move(answers));

    clearError();
    return json::serialize(state);
}

std::string Runtime::lastErrorJson() const
{
    json::Value error = json::Value::object();
    error.set("code", json::Value::string(errorCode_));
    error.set("message", json::Value::string(errorMessage_));
    error.set("details", json::Value::object());
    return json::serialize(error);
}

void Runtime::dispose()
{
    reset();
}

} // namespace rt
