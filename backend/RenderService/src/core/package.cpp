#include "package.hpp"

#include <algorithm>
#include <cmath>

namespace rt::pkg
{
namespace
{

// --- JS parity helpers -----------------------------------------------------
//
// The reference validator lives in adapter.js and runs on values produced by
// JSON.parse. The helpers below reproduce the exact truthiness rules it
// relies on (String.prototype.trim whitespace, strict/loose equality) so the
// two validators stay bit-compatible on the same document.

bool isJsWhitespace(std::uint32_t cp)
{
    switch (cp)
    {
    case 0x0009: case 0x000A: case 0x000B: case 0x000C: case 0x000D:
    case 0x0020: case 0x00A0: case 0x1680: case 0x2028: case 0x2029:
    case 0x202F: case 0x205F: case 0x3000: case 0xFEFF:
        return true;
    default:
        return cp >= 0x2000 && cp <= 0x200A;
    }
}

// Decodes one UTF-8 codepoint; malformed bytes decode as themselves so that
// arbitrary byte content never crashes emptiness checks.
std::uint32_t decodeUtf8(std::string_view text, std::size_t& index)
{
    const unsigned char first = static_cast<unsigned char>(text[index]);
    std::size_t extra = 0;
    std::uint32_t cp = first;
    if (first >= 0xF0)
    {
        extra = 3;
        cp = first & 0x07;
    }
    else if (first >= 0xE0)
    {
        extra = 2;
        cp = first & 0x0F;
    }
    else if (first >= 0xC0)
    {
        extra = 1;
        cp = first & 0x1F;
    }
    if (extra == 0)
    {
        ++index;
        return cp;
    }
    for (std::size_t i = 1; i <= extra; ++i)
    {
        if (index + i >= text.size())
        {
            ++index;
            return first;
        }
        const unsigned char follow = static_cast<unsigned char>(text[index + i]);
        if ((follow & 0xC0) != 0x80)
        {
            ++index;
            return first;
        }
        cp = (cp << 6) | (follow & 0x3F);
    }
    index += extra + 1;
    return cp;
}

bool isBlankString(std::string_view text)
{
    std::size_t index = 0;
    while (index < text.size())
    {
        if (!isJsWhitespace(decodeUtf8(text, index)))
        {
            return false;
        }
    }
    return true;
}

bool isNonEmptyString(const json::Value* value)
{
    return value != nullptr && value->isString() && !isBlankString(value->asString());
}

bool isUuidV4Member(const json::Value* value)
{
    return value != nullptr && value->isString() && isUuidV4(value->asString());
}

// Present with any value other than JSON null (JS `x != null`).
bool hasNonNull(const json::Value* value)
{
    return value != nullptr && !value->isNull();
}

// A comparison key reproducing JS strict equality (===) between two member
// values, where an absent member is `undefined`. Objects and arrays compare
// by reference in JS, so two distinct document nodes are never equal.
struct StrictKey
{
    enum class Kind : std::uint8_t
    {
        Missing,
        Null,
        Boolean,
        Number,
        String,
        Reference, // object/array: never equal to anything
    };

    Kind kind = Kind::Missing;
    std::string payload;
    bool neverEqual = false;

    static StrictKey of(const json::Value* value)
    {
        StrictKey key;
        if (value == nullptr)
        {
            key.kind = Kind::Missing;
            return key;
        }
        switch (value->type())
        {
        case json::Type::Null:
            key.kind = Kind::Null;
            break;
        case json::Type::Boolean:
            key.kind = Kind::Boolean;
            key.payload = value->asBoolean() ? "true" : "false";
            break;
        case json::Type::Number:
            key.kind = Kind::Number;
            if (std::isnan(value->asNumber()))
            {
                key.neverEqual = true; // NaN !== NaN
            }
            key.payload = json::serialize(*value);
            break;
        case json::Type::String:
            key.kind = Kind::String;
            key.payload = value->asString();
            break;
        case json::Type::Array:
        case json::Type::Object:
            key.kind = Kind::Reference;
            key.neverEqual = true;
            break;
        }
        return key;
    }

    bool equals(const StrictKey& other) const
    {
        if (neverEqual || other.neverEqual)
        {
            return false;
        }
        return kind == other.kind && payload == other.payload;
    }
};

bool contains(const std::vector<std::string>& values, std::string_view value)
{
    return std::find(values.begin(), values.end(), value) != values.end();
}

struct SceneReference
{
    std::string from;
    std::string to;
    std::string path;
};

void addIssue(std::vector<ValidationIssue>& errors, std::string path, std::string code,
              std::string message)
{
    errors.push_back(ValidationIssue{std::move(path), std::move(code), std::move(message)});
}

const json::Value* member(const json::Value& object, std::string_view key)
{
    return object.isObject() ? object.find(key) : nullptr;
}

bool isPurpose(const json::Value* value)
{
    if (value == nullptr || !value->isString())
    {
        return false;
    }
    const std::string& purpose = value->asString();
    return purpose == "EXPLAIN" || purpose == "QUESTION" || purpose == "FEEDBACK";
}

bool isAssetType(const json::Value* value)
{
    if (value == nullptr || !value->isString())
    {
        return false;
    }
    const std::string& type = value->asString();
    return type == "BACKGROUND" || type == "CHARACTER" || type == "AUDIO" || type == "OTHER";
}

} // namespace

bool isUuidV4(std::string_view value)
{
    if (value.size() != 36)
    {
        return false;
    }
    for (std::size_t i = 0; i < value.size(); ++i)
    {
        const char c = value[i];
        if (i == 8 || i == 13 || i == 18 || i == 23)
        {
            if (c != '-')
            {
                return false;
            }
            continue;
        }
        const bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        if (!hex)
        {
            return false;
        }
    }
    if (value[14] != '4')
    {
        return false;
    }
    const char variant = value[19];
    return variant == '8' || variant == '9' || variant == 'a' || variant == 'b';
}

json::Value ValidationResult::toJson() const
{
    json::Value root = json::Value::object();
    root.set("valid", json::Value::boolean(valid));
    json::Value list = json::Value::array();
    for (const ValidationIssue& issue : errors)
    {
        json::Value entry = json::Value::object();
        entry.set("path", json::Value::string(issue.path));
        entry.set("code", json::Value::string(issue.code));
        entry.set("message", json::Value::string(issue.message));
        list.push(std::move(entry));
    }
    root.set("errors", std::move(list));
    return root;
}

ValidationResult validate(const json::Value& root)
{
    ValidationResult result;
    std::vector<ValidationIssue>& errors = result.errors;

    if (!root.isObject())
    {
        addIssue(errors, "$", "PACKAGE_REQUIRED", "gamePackage must be an object");
        return result;
    }

    const json::Value* schemaVersion = member(root, "schemaVersion");
    if (schemaVersion == nullptr || !schemaVersion->isString()
        || schemaVersion->asString() != "1.0")
    {
        addIssue(errors, "$.schemaVersion", "SCHEMA_UNSUPPORTED",
                 "only schemaVersion 1.0 is supported");
    }
    if (!isUuidV4Member(member(root, "packageId")))
    {
        addIssue(errors, "$.packageId", "UUID_V4_REQUIRED",
                 "packageId must be a lowercase UUID v4");
    }
    if (!isNonEmptyString(member(root, "generatorVersion")))
    {
        addIssue(errors, "$.generatorVersion", "FIELD_REQUIRED", "generatorVersion is required");
    }
    if (!isUuidV4Member(member(root, "reviewPlanId")))
    {
        addIssue(errors, "$.reviewPlanId", "UUID_V4_REQUIRED",
                 "reviewPlanId must be a lowercase UUID v4");
    }
    if (!isNonEmptyString(member(root, "snapshotVersion")))
    {
        addIssue(errors, "$.snapshotVersion", "FIELD_REQUIRED", "snapshotVersion is required");
    }
    const json::Value* entrySceneId = member(root, "entrySceneId");
    if (!isNonEmptyString(entrySceneId))
    {
        addIssue(errors, "$.entrySceneId", "FIELD_REQUIRED", "entrySceneId is required");
    }

    const json::Value* scenes = member(root, "scenes");
    if (scenes == nullptr || !scenes->isArray() || scenes->items().size() < 1
        || scenes->items().size() > 100)
    {
        addIssue(errors, "$.scenes", "SCENE_COUNT_OUT_OF_RANGE", "scenes must contain 1-100 entries");
        if (scenes == nullptr || !scenes->isArray())
        {
            return result;
        }
    }
    const json::Value* assets = member(root, "assets");
    if (assets == nullptr || !assets->isArray())
    {
        addIssue(errors, "$.assets", "FIELD_REQUIRED", "assets must be an array");
    }

    std::vector<std::string> sceneIds;
    std::vector<std::string> questionIds;
    std::vector<std::string> questionSceneIds;
    std::vector<SceneReference> nextReferences;

    for (std::size_t index = 0; index < scenes->items().size(); ++index)
    {
        const json::Value& scene = scenes->items()[index];
        const std::string base = "$.scenes[" + std::to_string(index) + "]";
        if (!scene.isObject())
        {
            addIssue(errors, base, "SCENE_REQUIRED", "scene must be an object");
            continue;
        }

        const json::Value* sceneIdValue = member(scene, "sceneId");
        const bool sceneIdUsable = isNonEmptyString(sceneIdValue);
        const std::string sceneId =
            sceneIdValue != nullptr && sceneIdValue->isString() ? sceneIdValue->asString() : "";
        if (!sceneIdUsable || contains(sceneIds, sceneId))
        {
            addIssue(errors, base + ".sceneId", "SCENE_ID_INVALID",
                     "sceneId must be non-empty and unique");
        }
        else
        {
            sceneIds.push_back(sceneId);
        }

        const json::Value* dialogue = member(scene, "dialogue");
        if (dialogue == nullptr || !dialogue->isArray() || dialogue->items().size() < 1
            || dialogue->items().size() > 200)
        {
            addIssue(errors, base + ".dialogue", "DIALOGUE_COUNT_OUT_OF_RANGE",
                     "dialogue must contain 1-200 entries");
        }
        else
        {
            for (std::size_t lineIndex = 0; lineIndex < dialogue->items().size(); ++lineIndex)
            {
                const json::Value& line = dialogue->items()[lineIndex];
                if (!line.isObject() || !isNonEmptyString(member(line, "speakerId"))
                    || !isNonEmptyString(member(line, "text")))
                {
                    addIssue(errors, base + ".dialogue[" + std::to_string(lineIndex) + "]",
                             "DIALOGUE_INVALID", "speakerId and text are required");
                }
            }
        }

        const json::Value* choicesValue = member(scene, "choices");
        static const std::vector<json::Value> kNoValues;
        const std::vector<json::Value>& choices =
            (choicesValue != nullptr && choicesValue->isArray()) ? choicesValue->items()
                                                                 : kNoValues;
        if (choicesValue == nullptr || !choicesValue->isArray() || choices.size() > 6)
        {
            addIssue(errors, base + ".choices", "CHOICE_COUNT_OUT_OF_RANGE",
                     "choices must contain 0-6 entries");
        }

        std::vector<std::string> choiceIds;
        for (std::size_t choiceIndex = 0; choiceIndex < choices.size(); ++choiceIndex)
        {
            const json::Value& choice = choices[choiceIndex];
            const std::string choicePath =
                base + ".choices[" + std::to_string(choiceIndex) + "]";
            if (!choice.isObject())
            {
                addIssue(errors, choicePath, "CHOICE_INVALID", "choice must be an object");
                continue;
            }
            const json::Value* choiceIdValue = member(choice, "choiceId");
            const std::string choiceId =
                choiceIdValue != nullptr && choiceIdValue->isString() ? choiceIdValue->asString()
                                                                      : "";
            if (!isNonEmptyString(choiceIdValue) || contains(choiceIds, choiceId))
            {
                addIssue(errors, choicePath + ".choiceId", "CHOICE_ID_INVALID",
                         "choiceId must be non-empty and unique in its scene");
            }
            else
            {
                choiceIds.push_back(choiceId);
            }
            if (!isUuidV4Member(member(choice, "questionId")))
            {
                addIssue(errors, choicePath + ".questionId", "UUID_V4_REQUIRED",
                         "questionId must be UUID v4");
            }
            if (!isNonEmptyString(member(choice, "text")))
            {
                addIssue(errors, choicePath + ".text", "FIELD_REQUIRED", "choice text is required");
            }
            if (!isUuidV4Member(member(choice, "knowledgePointId")))
            {
                addIssue(errors, choicePath + ".knowledgePointId", "UUID_V4_REQUIRED",
                         "knowledgePointId must be UUID v4");
            }
            const json::Value* scoreDelta = member(choice, "scoreDelta");
            if (scoreDelta == nullptr || !scoreDelta->isNumber()
                || !std::isfinite(scoreDelta->asNumber()))
            {
                addIssue(errors, choicePath + ".scoreDelta", "NUMBER_REQUIRED",
                         "scoreDelta must be a finite number");
            }
            const json::Value* nextSceneId = member(choice, "nextSceneId");
            const bool nextIsNull = nextSceneId != nullptr && nextSceneId->isNull();
            if (!nextIsNull && !isNonEmptyString(nextSceneId))
            {
                addIssue(errors, choicePath + ".nextSceneId", "SCENE_REFERENCE_INVALID",
                         "nextSceneId must be null or a non-empty string");
            }
            else if (isNonEmptyString(nextSceneId))
            {
                nextReferences.push_back(SceneReference{
                    sceneId, nextSceneId->asString(), choicePath + ".nextSceneId"});
            }
        }

        const json::Value* bindingsValue = member(scene, "knowledgeBindings");
        const std::vector<json::Value>& bindings =
            (bindingsValue != nullptr && bindingsValue->isArray()) ? bindingsValue->items()
                                                                   : kNoValues;
        if (bindingsValue == nullptr || !bindingsValue->isArray())
        {
            addIssue(errors, base + ".knowledgeBindings", "FIELD_REQUIRED",
                     "knowledgeBindings must be an array");
        }
        for (std::size_t bindingIndex = 0; bindingIndex < bindings.size(); ++bindingIndex)
        {
            const json::Value& binding = bindings[bindingIndex];
            const std::string bindingPath =
                base + ".knowledgeBindings[" + std::to_string(bindingIndex) + "]";
            if (!binding.isObject())
            {
                addIssue(errors, bindingPath, "BINDING_INVALID",
                         "knowledge binding must be an object");
                continue;
            }
            if (!isUuidV4Member(member(binding, "knowledgePointId")))
            {
                addIssue(errors, bindingPath + ".knowledgePointId", "UUID_V4_REQUIRED",
                         "knowledgePointId must be UUID v4");
            }
            if (!isPurpose(member(binding, "purpose")))
            {
                addIssue(errors, bindingPath + ".purpose", "PURPOSE_INVALID", "purpose is invalid");
            }
            const json::Value* bindingQuestionId = member(binding, "questionId");
            const bool questionIdIsNull =
                bindingQuestionId != nullptr && bindingQuestionId->isNull();
            if (!questionIdIsNull && !isUuidV4Member(bindingQuestionId))
            {
                addIssue(errors, bindingPath + ".questionId", "UUID_V4_REQUIRED",
                         "questionId must be null or UUID v4");
            }
            const json::Value* purpose = member(binding, "purpose");
            const bool isQuestionPurpose =
                purpose != nullptr && purpose->isString() && purpose->asString() == "QUESTION";
            if (isQuestionPurpose && !isUuidV4Member(bindingQuestionId))
            {
                addIssue(errors, bindingPath + ".questionId", "QUESTION_ID_INVALID",
                         "QUESTION binding requires a UUID v4 questionId");
            }
        }

        std::vector<const json::Value*> questionBindings;
        for (const json::Value& binding : bindings)
        {
            const json::Value* purpose = member(binding, "purpose");
            if (binding.isObject() && purpose != nullptr && purpose->isString()
                && purpose->asString() == "QUESTION")
            {
                questionBindings.push_back(&binding);
            }
        }
        if (questionBindings.size() > 1)
        {
            addIssue(errors, base + ".knowledgeBindings", "QUESTION_BINDING_COUNT",
                     "a scene may contain at most one QUESTION binding");
        }
        if (questionBindings.size() == 1)
        {
            const json::Value& binding = *questionBindings.front();
            const json::Value* bindingQuestionId = member(binding, "questionId");
            const std::string bindingQuestionText =
                bindingQuestionId != nullptr && bindingQuestionId->isString()
                    ? bindingQuestionId->asString()
                    : "";
            if (!isUuidV4Member(bindingQuestionId) || contains(questionIds, bindingQuestionText))
            {
                addIssue(errors, base + ".knowledgeBindings", "QUESTION_ID_INVALID",
                         "questionId must be unique");
            }
            else
            {
                questionIds.push_back(bindingQuestionText);
            }
            if (sceneIdUsable && !contains(questionSceneIds, sceneId))
            {
                questionSceneIds.push_back(sceneId);
            }

            bool hasCorrectChoice = false;
            for (const json::Value& choice : choices)
            {
                const json::Value* correct =
                    choice.isObject() ? member(choice, "correct") : nullptr;
                if (correct != nullptr && correct->isBoolean() && correct->asBoolean())
                {
                    hasCorrectChoice = true;
                    break;
                }
            }
            if (choices.empty() || !hasCorrectChoice)
            {
                addIssue(errors, base + ".choices", "QUESTION_CHOICES_INVALID",
                         "a QUESTION needs choices and at least one correct answer");
            }

            const StrictKey bindingQuestionKey = StrictKey::of(bindingQuestionId);
            const StrictKey bindingPointKey = StrictKey::of(member(binding, "knowledgePointId"));
            bool mismatch = false;
            for (const json::Value& choice : choices)
            {
                if (!choice.isObject())
                {
                    mismatch = true;
                    break;
                }
                const json::Value* correct = member(choice, "correct");
                const json::Value* answerKind = member(choice, "answerKind");
                const bool answerKindIsChoice = answerKind != nullptr && answerKind->isString()
                                                && answerKind->asString() == "CHOICE";
                if (!StrictKey::of(member(choice, "questionId")).equals(bindingQuestionKey)
                    || correct == nullptr || !correct->isBoolean() || !answerKindIsChoice
                    || !StrictKey::of(member(choice, "knowledgePointId")).equals(bindingPointKey))
                {
                    mismatch = true;
                    break;
                }
            }
            if (mismatch)
            {
                addIssue(errors, base + ".choices", "QUESTION_BINDING_MISMATCH",
                         "choices must match the same-scene QUESTION binding");
            }
        }
        else
        {
            // JS parity: the reference validator's else-branch runs whenever
            // the scene does NOT have exactly one QUESTION binding — including
            // the >1 case that also reports QUESTION_BINDING_COUNT.
            bool scoringWithoutQuestion = false;
            for (const json::Value& choice : choices)
            {
                if (!choice.isObject())
                {
                    continue;
                }
                if (hasNonNull(member(choice, "answerKind"))
                    || hasNonNull(member(choice, "correct")))
                {
                    scoringWithoutQuestion = true;
                    break;
                }
            }
            if (scoringWithoutQuestion)
            {
                addIssue(errors, base + ".choices", "SCORING_WITHOUT_QUESTION",
                         "non-QUESTION scenes cannot carry answerKind/correct");
            }
        }
    }

    const std::string entrySceneText =
        entrySceneId != nullptr && entrySceneId->isString() ? entrySceneId->asString() : "";
    const bool entryExists =
        entrySceneId != nullptr && entrySceneId->isString() && contains(sceneIds, entrySceneText);
    if (!entryExists)
    {
        addIssue(errors, "$.entrySceneId", "ENTRY_SCENE_INVALID",
                 "entrySceneId must reference a scene");
    }
    for (const SceneReference& reference : nextReferences)
    {
        if (!contains(sceneIds, reference.to))
        {
            addIssue(errors, reference.path, "SCENE_REFERENCE_INVALID",
                     "nextSceneId must reference an existing scene");
        }
    }

    if (entryExists)
    {
        std::vector<std::string> reachable{entrySceneText};
        std::vector<std::string> pending{entrySceneText};
        while (!pending.empty())
        {
            const std::string current = pending.front();
            pending.erase(pending.begin());
            for (const SceneReference& reference : nextReferences)
            {
                if (reference.from == current && contains(sceneIds, reference.to)
                    && !contains(reachable, reference.to))
                {
                    reachable.push_back(reference.to);
                    pending.push_back(reference.to);
                }
            }
        }
        for (const std::string& questionSceneId : questionSceneIds)
        {
            if (!contains(reachable, questionSceneId))
            {
                addIssue(errors, "$.scenes", "UNREACHABLE_QUESTION_SCENE",
                         "QUESTION scene " + questionSceneId
                             + " is not reachable from entrySceneId");
            }
        }
    }

    if (assets != nullptr && assets->isArray())
    {
        for (std::size_t assetIndex = 0; assetIndex < assets->items().size(); ++assetIndex)
        {
            const json::Value& asset = assets->items()[assetIndex];
            const bool ok = asset.isObject() && isNonEmptyString(member(asset, "assetId"))
                            && isAssetType(member(asset, "type"))
                            && isNonEmptyString(member(asset, "uri"));
            if (!ok)
            {
                addIssue(errors, "$.assets[" + std::to_string(assetIndex) + "]", "ASSET_INVALID",
                         "assetId, supported type and uri are required");
            }
        }
    }

    result.valid = errors.empty();
    return result;
}

const Choice* Scene::findChoice(std::string_view id) const
{
    for (const Choice& choice : choices)
    {
        if (choice.choiceId == id)
        {
            return &choice;
        }
    }
    return nullptr;
}

const Scene* Package::findScene(std::string_view id) const
{
    for (const Scene& scene : scenes)
    {
        if (scene.sceneId == id)
        {
            return &scene;
        }
    }
    return nullptr;
}

Package build(const json::Value& root)
{
    Package package;
    const auto text = [](const json::Value* value) {
        return value != nullptr && value->isString() ? value->asString() : std::string();
    };
    package.packageId = text(member(root, "packageId"));
    package.generatorVersion = text(member(root, "generatorVersion"));
    package.reviewPlanId = text(member(root, "reviewPlanId"));
    package.snapshotVersion = text(member(root, "snapshotVersion"));
    package.entrySceneId = text(member(root, "entrySceneId"));

    const json::Value* scenes = member(root, "scenes");
    if (scenes == nullptr || !scenes->isArray())
    {
        return package;
    }
    for (const json::Value& sceneValue : scenes->items())
    {
        if (!sceneValue.isObject())
        {
            continue;
        }
        Scene scene;
        scene.sceneId = text(member(sceneValue, "sceneId"));
        const json::Value* dialogue = member(sceneValue, "dialogue");
        scene.dialogueCount =
            dialogue != nullptr && dialogue->isArray() ? dialogue->items().size() : 0;

        const json::Value* choices = member(sceneValue, "choices");
        if (choices != nullptr && choices->isArray())
        {
            for (const json::Value& choiceValue : choices->items())
            {
                if (!choiceValue.isObject())
                {
                    continue;
                }
                Choice choice;
                choice.choiceId = text(member(choiceValue, "choiceId"));
                choice.questionId = text(member(choiceValue, "questionId"));
                choice.text = text(member(choiceValue, "text"));
                const json::Value* nextSceneId = member(choiceValue, "nextSceneId");
                if (nextSceneId != nullptr && nextSceneId->isString())
                {
                    choice.hasNextScene = true;
                    choice.nextSceneId = nextSceneId->asString();
                }
                const json::Value* scoreDelta = member(choiceValue, "scoreDelta");
                choice.scoreDelta =
                    scoreDelta != nullptr && scoreDelta->isNumber() ? scoreDelta->asNumber() : 0.0;
                choice.knowledgePointId = text(member(choiceValue, "knowledgePointId"));
                const json::Value* correct = member(choiceValue, "correct");
                if (correct != nullptr && correct->isBoolean())
                {
                    choice.hasCorrect = true;
                    choice.correct = correct->asBoolean();
                }
                scene.choices.push_back(std::move(choice));
            }
        }

        const json::Value* bindings = member(sceneValue, "knowledgeBindings");
        if (bindings != nullptr && bindings->isArray())
        {
            for (const json::Value& bindingValue : bindings->items())
            {
                if (!bindingValue.isObject())
                {
                    continue;
                }
                const json::Value* purpose = member(bindingValue, "purpose");
                if (purpose != nullptr && purpose->isString() && purpose->asString() == "QUESTION"
                    && !scene.hasQuestion)
                {
                    scene.hasQuestion = true;
                    scene.questionId = text(member(bindingValue, "questionId"));
                    scene.questionPointId = text(member(bindingValue, "knowledgePointId"));
                }
            }
        }
        package.scenes.push_back(std::move(scene));
    }
    return package;
}

} // namespace rt::pkg
