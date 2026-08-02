// RenderService runtime core - GamePackage schema 1.0 validation and model.
//
// The validation rules mirror docs/contract.md §7.3/§7.3.1 and are kept in
// behavioural parity with the JS reference validator served as adapter.js
// (same codes, same paths, same JS strict/loose comparison quirks) so that
// the browser and the WASM core cannot disagree about a package.
#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

#include "json.hpp"

namespace rt::pkg
{

struct ValidationIssue
{
    std::string path;
    std::string code;
    std::string message;
};

struct ValidationResult
{
    bool valid = false;
    std::vector<ValidationIssue> errors;

    json::Value toJson() const;
};

struct Choice
{
    std::string choiceId;
    std::string questionId;
    std::string text;
    bool hasNextScene = false; // nextSceneId was a non-null string
    std::string nextSceneId;
    double scoreDelta = 0.0;
    std::string knowledgePointId;
    bool hasCorrect = false; // correct present as a boolean
    bool correct = false;
};

struct Scene
{
    std::string sceneId;
    std::size_t dialogueCount = 0;
    std::vector<Choice> choices;
    bool hasQuestion = false;   // scene declares a QUESTION binding
    std::string questionId;     // valid when hasQuestion
    std::string questionPointId;

    const Choice* findChoice(std::string_view choiceId) const;
};

struct Package
{
    std::string packageId;
    std::string generatorVersion;
    std::string reviewPlanId;
    std::string snapshotVersion;
    std::string entrySceneId;
    std::vector<Scene> scenes;

    const Scene* findScene(std::string_view sceneId) const;
};

// Lowercase UUID v4, e.g. 6428a20a-66dd-44c9-944f-d7b36fa9c95a.
bool isUuidV4(std::string_view value);

// Full package validation over a parsed JSON document.
ValidationResult validate(const json::Value& root);

// Builds the runtime model. Precondition: validate(root).valid == true.
Package build(const json::Value& root);

} // namespace rt::pkg
