using MongoDB.Bson;
using MongoDB.Bson.Serialization;
using MongoDB.Bson.Serialization.Conventions;
using MongoDB.Bson.Serialization.Serializers;

namespace PracticeService.Persistence;

public static class MongoMappings
{
    private static int _registered;

    public static void EnsureRegistered()
    {
        if (Interlocked.Exchange(ref _registered, 1) == 1) return;
        // MongoDB.Driver 3.x 不再为 Guid 隐式选择表示。Practice 的项目、题目、会话、任务与
        // 共享包都以 Guid 为业务主键，统一使用跨语言可读的 Standard 表示。
        BsonSerializer.TryRegisterSerializer(new GuidSerializer(GuidRepresentation.Standard));
        // 聚合使用显式业务主键（ProjectId、QuestionId 等），MongoDB 仍会自动为文档补充
        // `_id`。这些存储层字段不属于领域模型，反序列化时必须忽略，否则创建后的第一次
        // 查询就会因 `_id` 无对应属性而失败。
        ConventionRegistry.Register(
            "PracticeService.Domain.IgnoreMongoMetadata",
            new ConventionPack { new IgnoreExtraElementsConvention(true) },
            type => type.Namespace == typeof(PracticeService.Domain.StudyProject).Namespace);
    }
}
