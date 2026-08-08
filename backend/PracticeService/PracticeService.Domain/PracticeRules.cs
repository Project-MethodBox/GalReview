using System.Security.Cryptography;
using System.Text;

namespace PracticeService.Domain;

public sealed record QuestionDraft(
    PracticeQuestionKind Kind, string Prompt, IReadOnlyList<QuestionOption> Options,
    IReadOnlyList<string> CorrectAnswers, string? Explanation, decimal Score, int Difficulty,
    Guid? KnowledgePointId, IReadOnlyList<SourceReference> SourceReferences, QuestionStatus Status);

public static class PracticeRules
{
    public static PracticeQuestion CreateQuestion(StudyProject project, QuestionDraft draft, Guid? id = null, int version = 1, DateTimeOffset? createdAt = null)
    {
        var prompt = draft.Prompt.Trim();
        if (prompt.Length is < 1 or > 4000) Invalid("prompt 必须包含 1-4000 个字符。");
        if (draft.Score is <= 0 or > 100) Invalid("score 必须在 (0,100] 范围内。");
        if (draft.Difficulty is < 1 or > 5) Invalid("difficulty 必须在 1-5 范围内。");
        var options = draft.Options.Select(x => new QuestionOption(NormalizeOptionId(x.Id), x.Text.Trim())).ToArray();
        var answers = draft.CorrectAnswers.Select(NormalizeAnswer).Where(x => x.Length > 0).ToArray();
        ValidateAnswerShape(draft.Kind, options, answers);
        var now = DateTimeOffset.UtcNow;
        return new PracticeQuestion(id ?? Guid.NewGuid(), project.ProjectId, project.QuestionBankId, draft.Kind,
            prompt, options, answers, string.IsNullOrWhiteSpace(draft.Explanation) ? null : draft.Explanation.Trim(),
            draft.Score, draft.Difficulty, draft.KnowledgePointId, draft.SourceReferences.ToArray(), draft.Status,
            version, createdAt ?? now, now);
    }

    public static void ValidateAnswerShape(PracticeQuestionKind kind, IReadOnlyList<QuestionOption> options, IReadOnlyList<string> answers)
    {
        if (answers.Count == 0) AnswerInvalid("题目必须包含正确答案。");
        if (kind == PracticeQuestionKind.SingleChoice)
        {
            if (options.Count is < 2 or > 8 || options.Select(x => x.Id).Distinct(StringComparer.Ordinal).Count() != options.Count)
                AnswerInvalid("单选题必须有 2-8 个且 ID 唯一的选项。");
            if (answers.Count != 1 || !options.Any(x => x.Id == NormalizeOptionId(answers[0])))
                AnswerInvalid("单选题正确答案必须指向一个现有选项。");
        }
        else if (options.Count != 0) AnswerInvalid("只有单选题可以包含 options。");
        if (kind == PracticeQuestionKind.TrueFalse && (answers.Count != 1 || NormalizeTrueFalse(answers[0]) is null))
            AnswerInvalid("判断题答案必须是可识别的 true 或 false。");
    }

    public static IReadOnlyList<PracticeQuestion> SelectQuestions(
        IReadOnlyList<PracticeQuestion> candidates, int count, int seed,
        IReadOnlyCollection<PracticeQuestionKind>? kinds = null, IReadOnlySet<Guid>? knowledgePointIds = null)
    {
        if (count is < 1 or > 200) Invalid("questionCount 必须在 1-200 范围内。");
        var filtered = candidates.Where(x => x.Status == QuestionStatus.Ready);
        if (kinds is { Count: > 0 }) filtered = filtered.Where(x => kinds.Contains(x.Kind));
        if (knowledgePointIds is { Count: > 0 }) filtered = filtered.Where(x => x.KnowledgePointId is Guid id && knowledgePointIds.Contains(id));
        return filtered.OrderBy(x => Sha256($"{seed}:{x.QuestionId:D}")).Take(count).ToArray();
    }

    public static IReadOnlyList<PracticeQuestion> GenerateExam(
        IReadOnlyList<PracticeQuestion> candidates, int count, int seed,
        IReadOnlyDictionary<PracticeQuestionKind, int>? requestedCounts)
    {
        var ready = candidates.Where(x => x.Status == QuestionStatus.Ready).ToArray();
        if (ready.Length < count) throw new PracticeDomainException(422, "NOT_ENOUGH_QUESTIONS", "题库中的 READY 题目不足以组卷。");
        var counts = requestedCounts is { Count: > 0 } ? new(requestedCounts) : DefaultExamCounts(count);
        if (counts.Values.Any(x => x < 0) || counts.Values.Sum() != count) Invalid("kindCounts 之和必须等于 questionCount。");
        var selected = new List<PracticeQuestion>();
        foreach (var pair in counts.OrderBy(x => (int)x.Key))
        {
            var pool = ready.Where(x => x.Kind == pair.Key).ToArray();
            if (pool.Length < pair.Value) throw new PracticeDomainException(422, "NOT_ENOUGH_QUESTIONS", $"{pair.Key} 题目不足，需要 {pair.Value} 道。");
            selected.AddRange(SelectQuestions(pool, pair.Value, seed ^ (int)pair.Key));
        }
        return selected;
    }

    public static string? NormalizeTrueFalse(string value) => NormalizeAnswer(value).ToLowerInvariant() switch
    {
        "true" or "t" or "yes" or "正确" or "对" or "是" or "√" => "true",
        "false" or "f" or "no" or "错误" or "错" or "否" or "×" or "x" => "false",
        _ => null
    };
    public static string NormalizeAnswer(string value) => string.Join(' ', (value ?? string.Empty).Normalize(NormalizationForm.FormC).Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
    public static string NormalizeOptionId(string value)
    {
        var id = NormalizeAnswer(value).ToUpperInvariant();
        if (id.Length is < 1 or > 8) AnswerInvalid("选项 ID 长度必须为 1-8。");
        return id;
    }
    public static double LevenshteinSimilarity(string left, string right)
    {
        left = NormalizeAnswer(left); right = NormalizeAnswer(right);
        if (left == right) return 1;
        if (left.Length == 0 || right.Length == 0) return 0;
        var previous = Enumerable.Range(0, right.Length + 1).ToArray(); var current = new int[right.Length + 1];
        for (var i = 1; i <= left.Length; i++)
        {
            current[0] = i;
            for (var j = 1; j <= right.Length; j++) current[j] = Math.Min(Math.Min(current[j - 1] + 1, previous[j] + 1), previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1));
            (previous, current) = (current, previous);
        }
        return Math.Clamp(1d - previous[right.Length] / (double)Math.Max(left.Length, right.Length), 0, 1);
    }
    public static string Sha256(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
    public static string Sha256(byte[] value) => Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();

    private static Dictionary<PracticeQuestionKind, int> DefaultExamCounts(int count)
    {
        var choice = (int)Math.Round(count * .30, MidpointRounding.AwayFromZero); var remaining = count - choice;
        var blank = (int)Math.Round(remaining * .35, MidpointRounding.AwayFromZero); var term = (int)Math.Round(remaining * .20, MidpointRounding.AwayFromZero);
        return new() { [PracticeQuestionKind.SingleChoice] = choice, [PracticeQuestionKind.FillBlank] = blank,
            [PracticeQuestionKind.TermDefinition] = term, [PracticeQuestionKind.Essay] = remaining - blank - term };
    }
    private static void Invalid(string message) => throw new PracticeDomainException(400, "VALIDATION_ERROR", message);
    private static void AnswerInvalid(string message) => throw new PracticeDomainException(422, "QUESTION_ANSWER_INVALID", message);
}
