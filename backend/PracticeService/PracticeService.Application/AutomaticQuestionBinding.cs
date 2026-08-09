using PracticeService.Domain;

namespace PracticeService.Application;

public static class AutomaticQuestionBinding
{
    public static async Task<KnowledgePointBindingResult> ResolveAsync(
        StudyProject project,
        PracticeQuestionKind kind,
        string prompt,
        IReadOnlyList<QuestionOption> options,
        IReadOnlyList<string> answers,
        IReadOnlyList<SourceReference> sourceReferences,
        IReadOnlyList<PlanGraphPoint> points,
        IPracticeGateway gateway,
        IDictionary<Guid, MaterialText> materialCache,
        CancellationToken cancellationToken)
    {
        var evidence = await ReadVerifiedEvidenceAsync(project, sourceReferences, gateway, materialCache, cancellationToken);
        if (evidence is null || !KnowledgePointBindingRules.EvidenceSupportsQuestion(kind, options, answers, evidence))
            return new(null, false, "SOURCE_NOT_VERIFIED");
        return KnowledgePointBindingRules.Bind(kind, prompt, answers, evidence, points, sourceReferences);
    }

    public static async Task<int> ReconcileDraftsAsync(
        StudyProject project,
        IReadOnlyList<PlanGraphPoint> points,
        IPracticeRepository repository,
        IPracticeGateway gateway,
        CancellationToken cancellationToken)
    {
        if (points.Count == 0) return 0;
        var repaired = 0;
        var materials = new Dictionary<Guid, MaterialText>();
        var drafts = repository.ListQuestions(project.ProjectId)
            .Where(question => question.Status == QuestionStatus.Draft
                && !question.KnowledgePointId.HasValue
                && question.SourceReferences.Count > 0)
            .ToArray();
        foreach (var question in drafts)
        {
            KnowledgePointBindingResult binding;
            try
            {
                binding = await ResolveAsync(project, question.Kind, question.Prompt, question.Options,
                    question.CorrectAnswers, question.SourceReferences, points, gateway, materials, cancellationToken);
            }
            catch (OperationCanceledException) { throw; }
            catch { continue; }
            if (!binding.PointId.HasValue) continue;

            var updated = PracticeRules.CreateQuestion(project,
                new QuestionDraft(question.Kind, question.Prompt, question.Options, question.CorrectAnswers,
                    question.Explanation, question.Score, question.Difficulty, binding.PointId,
                    question.SourceReferences, QuestionStatus.Ready),
                question.QuestionId, question.Version + 1, question.CreatedAt);
            repository.SaveQuestion(updated);
            repaired++;
        }
        return repaired;
    }

    private static async Task<string?> ReadVerifiedEvidenceAsync(
        StudyProject project,
        IReadOnlyList<SourceReference> references,
        IPracticeGateway gateway,
        IDictionary<Guid, MaterialText> materialCache,
        CancellationToken cancellationToken)
    {
        if (references.Count == 0) return null;
        var excerpts = new List<string>();
        foreach (var source in references)
        {
            if (!project.MaterialIds.Contains(source.MaterialId)) return null;
            if (!materialCache.TryGetValue(source.MaterialId, out var material))
            {
                material = await gateway.GetMaterialTextAsync(source.MaterialId, cancellationToken);
                materialCache[source.MaterialId] = material;
            }
            if (material.OwnerUserId != project.OwnerUserId
                || !string.Equals(material.SourceMapVersion, source.SourceMapVersion, StringComparison.Ordinal)
                || source.StartOffset < 0
                || source.EndOffset <= source.StartOffset
                || source.EndOffset > material.Text.Length) return null;
            var excerpt = material.Text[(int)source.StartOffset..(int)source.EndOffset];
            if (!string.Equals(PracticeRules.Sha256(excerpt), source.ExcerptChecksum, StringComparison.OrdinalIgnoreCase))
                return null;
            excerpts.Add(excerpt);
        }
        return string.Join('\n', excerpts);
    }
}
