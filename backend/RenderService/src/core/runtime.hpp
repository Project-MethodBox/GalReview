// RenderService runtime core - the state machine behind the frozen §8.3 ABI.
//
// Call order: initialize -> loadPackage -> startSession -> dispatchInput /
// renderFrame / serializeState -> dispose. Out-of-order calls fail with a
// stable error code retrievable via lastErrorJson(). The runtime is a pure
// logic core: it owns validation, navigation, scoring and answer tracking,
// while visual presentation stays in the frontend (contract.md §8.3).
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "package.hpp"

namespace rt
{

inline constexpr const char* kRuntimeVersion = "cpp-wasm-0.2.0";
inline constexpr std::uint32_t kAbiVersion = 1;
inline constexpr const char* kStateSchemaVersion = "render-runtime-state-1";

class Runtime
{
public:
    // Resets everything, then parses configJson (must be a JSON object).
    // Returns false and stays uninitialized when the config is unusable.
    bool initialize(std::string_view configJson);

    // Always returns a ValidationResult JSON document. A valid package
    // replaces the previous one and ends any active session; an invalid one
    // leaves the previously loaded package untouched (JS adapter parity).
    std::string loadPackage(std::string_view packageJson);

    // Accepts a ReviewSession JSON document whose packageId / reviewPlanId /
    // snapshotVersion must match the loaded package. Restarting an active or
    // completed session is allowed and resets progress.
    bool startSession(std::string_view sessionJson);

    // RuntimeInput v1 -> RenderEvent[] v1. Rejected inputs return "[]" and
    // set the last error without mutating session state.
    std::string dispatchInput(std::string_view inputJson);

    // Accumulates elapsed time while a session is running. Never fails.
    void renderFrame(double deltaMs);

    // RuntimeState v1 JSON, or "null" when no session was started.
    std::string serializeState();

    // RuntimeError JSON: {"code","message","details":{}}; NO_ERROR when idle.
    std::string lastErrorJson() const;

    void dispose();

private:
    struct AnswerRecord
    {
        std::string sceneId;
        std::string questionId;
        std::string knowledgePointId;
        std::string choiceId;
        bool correct = false;
        double scoreDelta = 0.0;
        int attemptNumber = 1;
        bool hasAttemptId = false;
        std::string attemptId;
        bool hasOccurredAt = false;
        std::string occurredAt;
    };

    void reset();
    void setError(std::string code, std::string message);
    void clearError();
    const pkg::Scene* currentScene() const;
    json::Value sessionCompletedEvent() const;

    bool initialized_ = false;
    bool packageLoaded_ = false;
    pkg::Package package_;

    bool sessionActive_ = false;
    bool completed_ = false;
    std::string sessionId_;
    std::string userId_;
    std::string currentSceneId_;
    std::vector<std::string> visitedSceneIds_;
    double score_ = 0.0;
    double elapsedMs_ = 0.0;
    std::vector<AnswerRecord> answers_;

    std::string errorCode_ = "NO_ERROR";
    std::string errorMessage_;
};

} // namespace rt
