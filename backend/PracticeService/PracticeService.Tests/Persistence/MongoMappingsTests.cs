using MongoDB.Bson;
using MongoDB.Bson.Serialization;
using PracticeService.Domain;
using PracticeService.Persistence;
using Xunit;

namespace PracticeService.Tests.Persistence;

public sealed class MongoMappingsTests
{
    [Fact]
    public void Practice_guids_serialize_as_uuid_standard()
    {
        MongoMappings.EnsureRegistered(); var now = DateTimeOffset.UtcNow;
        var project = new StudyProject(Guid.NewGuid(), Guid.NewGuid(), "项目", "CS", [Guid.NewGuid()], null,
            Guid.NewGuid(), ProjectStatus.Active, 1, now, now);

        var document = project.ToBsonDocument();

        Assert.Equal(BsonType.Binary, document[nameof(StudyProject.ProjectId)].BsonType);
        Assert.Equal(BsonBinarySubType.UuidStandard, document[nameof(StudyProject.ProjectId)].AsBsonBinaryData.SubType);
        Assert.Equal(BsonBinarySubType.UuidStandard, document[nameof(StudyProject.OwnerUserId)].AsBsonBinaryData.SubType);
    }

    [Fact]
    public void Mongo_generated_id_is_ignored_when_reading_domain_aggregate()
    {
        MongoMappings.EnsureRegistered(); var now = DateTimeOffset.UtcNow;
        var project = new StudyProject(Guid.NewGuid(), Guid.NewGuid(), "项目", "CS", [Guid.NewGuid()], null,
            Guid.NewGuid(), ProjectStatus.Active, 1, now, now);
        var document = project.ToBsonDocument();
        document.InsertAt(0, new BsonElement("_id", ObjectId.GenerateNewId()));

        var restored = BsonSerializer.Deserialize<StudyProject>(document);

        Assert.Equal(project.ProjectId, restored.ProjectId);
        Assert.Equal(project.OwnerUserId, restored.OwnerUserId);
        Assert.Equal(project.Name, restored.Name);
        Assert.Equal(project.MaterialIds, restored.MaterialIds);
        Assert.Equal(project.QuestionBankId, restored.QuestionBankId);
    }
}
