using PracticeService.Domain;
using PracticeService.Persistence;
using System.IO.Compression;
using System.Text;
using Xunit;

namespace PracticeService.Tests.Persistence;

public sealed class PracticePackageCodecTests
{
    private readonly PracticePackageCodec _codec = new();

    [Fact]
    public void Legacy_rhproj_maps_all_five_question_kinds()
    {
        const string json = """
        {"name":"旧项目","chapter":[{"name":"第一章","bank":[
          {"text":"选择","type":"SingleChoice","options":[{"id":"A","text":"甲"},{"id":"B","text":"乙"}],"correct_option_ids":["A"]},
          {"text":"填____","type":"FillBlank","correct_answers":["空"]},
          {"text":"判断","type":"TrueFalse","correct_answer":"正确"},
          {"text":"名词","type":"TermDefinition","correct_answer":"定义"},
          {"text":"简答","type":"Essay","correct_answer":"答案"}
        ]}]}
        """;

        var result = _codec.Decode("legacy.rhproj", Encoding.UTF8.GetBytes(json));

        Assert.Equal("recitehelper-rhproj", result.ImportedFromSchema);
        Assert.Equal(5, result.Questions.Count);
        Assert.Equal(Enum.GetValues<PracticeQuestionKind>().Order(), result.Questions.Select(x => x.Kind).Order());
        Assert.All(result.Questions, x => Assert.Equal(QuestionStatus.Ready, x.Status));
    }

    [Fact]
    public void Current_package_round_trips_with_hash_verification()
    {
        var owner = Guid.NewGuid(); var now = DateTimeOffset.UtcNow;
        var project = new StudyProject(Guid.NewGuid(), owner, "离散数学", "MATH", [Guid.NewGuid()], null, Guid.NewGuid(), ProjectStatus.Active, 1, now, now);
        var question = PracticeRules.CreateQuestion(project, new QuestionDraft(PracticeQuestionKind.Essay, "说明集合。", [], ["集合是对象的汇集。"], null, 5, 3, null, [], QuestionStatus.Ready));

        var encoded = _codec.Encode(project, [question]);
        var decoded = _codec.Decode(encoded.FileName, encoded.Content);

        Assert.Equal("qzwl-practice-package-1.0", decoded.ImportedFromSchema);
        Assert.Equal(project.Name, decoded.Name);
        Assert.Single(decoded.Questions);
    }

    [Fact]
    public void Archive_rejects_parent_path_entries()
    {
        using var stream = new MemoryStream();
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, true))
        {
            var entry = archive.CreateEntry("../escape.rhproj");
            using var writer = new StreamWriter(entry.Open()); writer.Write("{}");
        }

        var error = Assert.Throws<PracticeDomainException>(() => _codec.Decode("unsafe.rhp", stream.ToArray()));
        Assert.Equal("PACKAGE_ENTRY_UNSAFE", error.Code);
    }
}
