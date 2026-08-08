using MediatR;
using PracticeService.Domain;

namespace PracticeService.Application;

public sealed record ImportPracticePackageCommand(Guid OwnerUserId, string FileName, byte[] Content,
    IReadOnlyList<Guid> MaterialIds) : IRequest<PackageImportResult>;
public sealed record PackageImportResult(StudyProject Project, int ImportedQuestionCount, string ImportedFromSchema,
    IReadOnlyList<string> Diagnostics);
public sealed record ExportPracticePackageQuery(Guid OwnerUserId, Guid ProjectId) : IRequest<PracticePackageContent>;
public sealed record PublishPracticePackageCommand(Guid OwnerUserId, Guid ProjectId, string Version, string? Title,
    PackageVisibility Visibility) : IRequest<SharedPracticePackage>;
public sealed record SearchSharedPracticePackagesQuery(Guid OwnerUserId, string? Query, string? SubjectCode) : IRequest<IReadOnlyList<SharedPracticePackage>>;
public sealed record GetSharedPracticePackageContentQuery(Guid OwnerUserId, Guid PackageId) : IRequest<PracticePackageContent>;

public sealed class PackageHandlers(IPracticeRepository repository, IPracticePackageCodec codec, ISharedPracticePackageStore store, IPracticeGateway gateway) :
    IRequestHandler<ImportPracticePackageCommand, PackageImportResult>, IRequestHandler<ExportPracticePackageQuery, PracticePackageContent>,
    IRequestHandler<PublishPracticePackageCommand, SharedPracticePackage>, IRequestHandler<SearchSharedPracticePackagesQuery, IReadOnlyList<SharedPracticePackage>>,
    IRequestHandler<GetSharedPracticePackageContentQuery, PracticePackageContent>
{
    public async Task<PackageImportResult> Handle(ImportPracticePackageCommand request, CancellationToken ct)
    {
        var materials = request.MaterialIds.Where(x => x != Guid.Empty).Distinct().ToArray();
        if (materials.Length is < 1 or > 20)
            throw new PracticeDomainException(400, "PROJECT_MATERIALS_REQUIRED", "导入时必须映射 1-20 份当前用户的 READY 资料。");
        foreach (var materialId in materials)
        {
            var material = await gateway.GetMaterialTextAsync(materialId, ct);
            if (material.OwnerUserId != request.OwnerUserId) throw PracticeOwnership.NotFound();
        }
        var decoded = codec.Decode(request.FileName, request.Content);
        var name = string.IsNullOrWhiteSpace(decoded.Name) ? "导入的复习项目" : decoded.Name.Trim();
        if (name.Length > 120) name = name[..120];
        var now = DateTimeOffset.UtcNow;
        var project = repository.CreateProject(new StudyProject(Guid.NewGuid(), request.OwnerUserId, name, NormalizeSubject(decoded.SubjectCode),
            materials, null, Guid.NewGuid(), ProjectStatus.Active, 1, now, now));
        var diagnostics = decoded.Diagnostics.ToList(); var imported = 0;
        foreach (var draft in decoded.Questions.Take(10000))
        {
            try { repository.CreateQuestion(PracticeRules.CreateQuestion(project, draft)); imported++; }
            catch (PracticeDomainException error) { diagnostics.Add($"QUESTION_SKIPPED:{error.Code}:{error.Message}"); }
        }
        if (imported == 0) throw new PracticeDomainException(422, "PACKAGE_NO_VALID_QUESTIONS", "项目包中没有可导入的有效题目。", new { diagnostics });
        return new PackageImportResult(project, imported, decoded.ImportedFromSchema, diagnostics);
    }

    public Task<PracticePackageContent> Handle(ExportPracticePackageQuery request, CancellationToken ct)
    {
        var project = PracticeOwnership.Project(request.ProjectId, request.OwnerUserId, repository);
        return Task.FromResult(codec.Encode(project, repository.ListQuestions(project.ProjectId).Where(x => x.Status != QuestionStatus.Deleted).ToArray()));
    }

    public Task<SharedPracticePackage> Handle(PublishPracticePackageCommand request, CancellationToken ct)
    {
        var project = PracticeOwnership.Project(request.ProjectId, request.OwnerUserId, repository);
        var version = request.Version.Trim();
        if (version.Length is < 1 or > 64 || version.Any(char.IsControl)) throw new PracticeDomainException(400, "VALIDATION_ERROR", "version 必须包含 1-64 个可见字符。");
        var existing = store.FindVersion(request.OwnerUserId, project.ProjectId, version);
        if (existing is not null) return Task.FromResult(existing);
        var content = codec.Encode(project, repository.ListQuestions(project.ProjectId).Where(x => x.Status != QuestionStatus.Deleted).ToArray());
        var title = string.IsNullOrWhiteSpace(request.Title) ? project.Name : request.Title.Trim();
        if (title.Length > 120) throw new PracticeDomainException(400, "VALIDATION_ERROR", "title 最多 120 个字符。");
        var package = new SharedPracticePackage(Guid.NewGuid(), request.OwnerUserId, project.ProjectId, version, title, project.SubjectCode,
            request.Visibility, PracticeRules.Sha256(content.Content), content.Content.LongLength, 0, DateTimeOffset.UtcNow, null);
        return Task.FromResult(store.Save(package, content.Content));
    }

    public Task<IReadOnlyList<SharedPracticePackage>> Handle(SearchSharedPracticePackagesQuery request, CancellationToken ct) =>
        Task.FromResult(store.Search(request.OwnerUserId, request.Query, NormalizeSubject(request.SubjectCode)));

    public Task<PracticePackageContent> Handle(GetSharedPracticePackageContentQuery request, CancellationToken ct)
    {
        var package = store.Get(request.PackageId);
        if (package is null || package.WithdrawnAt is not null || (package.Visibility == PackageVisibility.Private && package.OwnerUserId != request.OwnerUserId))
            throw PracticeOwnership.NotFound();
        var bytes = store.ReadContent(package.PackageId) ?? throw PracticeOwnership.NotFound();
        if (!string.Equals(PracticeRules.Sha256(bytes), package.ContentSha256, StringComparison.Ordinal))
            throw new PracticeDomainException(500, "PACKAGE_CONTENT_CORRUPTED", "共享包内容校验失败。");
        store.SaveMetadata(package with { DownloadCount = package.DownloadCount + 1 });
        return Task.FromResult(new PracticePackageContent($"{SafeName(package.Title)}-{SafeName(package.Version)}.qzwlp", "application/zip", bytes));
    }

    private static string? NormalizeSubject(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var result = value.Trim().ToUpperInvariant();
        if (!System.Text.RegularExpressions.Regex.IsMatch(result, "^[A-Z][A-Z0-9_]{0,31}$"))
            throw new PracticeDomainException(400, "VALIDATION_ERROR", "subjectCode 格式无效。");
        return result;
    }
    private static string SafeName(string value) => string.Concat(value.Select(x => char.IsLetterOrDigit(x) || x is '-' or '_' ? x : '_'));
}
