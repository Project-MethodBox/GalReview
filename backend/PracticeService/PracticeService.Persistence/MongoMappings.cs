using MongoDB.Bson;
using MongoDB.Bson.Serialization;
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
    }
}
