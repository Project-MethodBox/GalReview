using System.Text.Json;
using Xunit;

// ============================================================================
// JSON Schema 1.0 契约测试
//
// 验证 backend/GalGameService/schema/game-package-1.0.schema.json 是合法 JSON、声明正确
// draft 版本与标题，并编码了 OWNER-TBD 冻结的数量上限与枚举。本测试只校验 Schema 文件
// 自身的结构完整性与关键约束，不做完整 JSON Schema 求值（求值由 RenderService / CI 在
// 消费侧用专用库执行）。
// ============================================================================

public class GamePackageSchemaTests
{
    private const string SchemaFileName = "game-package-1.0.schema.json";

    private static JsonDocument LoadSchema()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "schema", SchemaFileName);
        if (!File.Exists(path))
            throw new FileNotFoundException($"Schema 文件未找到：{path}。请确认 csproj 已配置 CopyToOutputDirectory。", path);

        return JsonDocument.Parse(File.ReadAllText(path));
    }

    private static JsonElement Prop(JsonElement obj, string name)
    {
        Assert.True(obj.TryGetProperty(name, out var value), $"Schema 缺少属性 {name}");
        return value;
    }

    [Fact]
    public void Schema_IsValidJson_WithDraft07AndTitle()
    {
        using var doc = LoadSchema();
        var root = doc.RootElement;
        Assert.Equal(JsonValueKind.Object, root.ValueKind);

        var schemaUri = Prop(root, "$schema").GetString();
        Assert.NotNull(schemaUri);
        Assert.Contains("draft-07", schemaUri);

        Assert.Equal("game-package-1.0", Prop(root, "title").GetString());
    }

    [Fact]
    public void Schema_DeclaresAllTopLevelRequiredFields()
    {
        using var doc = LoadSchema();
        var required = Prop(doc.RootElement, "required");
        var requiredList = required.EnumerateArray().Select(e => e.GetString()!).ToHashSet();
        foreach (var field in new[]
        {
            "schemaVersion", "packageId", "generatorVersion", "reviewPlanId",
            "snapshotVersion", "entrySceneId", "scenes", "assets"
        })
        {
            Assert.Contains(field, requiredList);
        }
    }

    [Fact]
    public void Schema_FixesSchemaVersion_Const_OneDotZero()
    {
        using var doc = LoadSchema();
        var sv = Prop(Prop(doc.RootElement, "properties"), "schemaVersion");
        Assert.Equal("1.0", Prop(sv, "const").GetString());
    }

    [Fact]
    public void Schema_EncodesFrozenCountLimits()
    {
        using var doc = LoadSchema();
        var properties = Prop(doc.RootElement, "properties");
        var defs = Prop(doc.RootElement, "$defs");

        // scenes: minItems 1, maxItems 100
        var scenes = Prop(properties, "scenes");
        Assert.Equal(1, Prop(scenes, "minItems").GetInt32());
        Assert.Equal(GamePackageValidator.MaxScenes, Prop(scenes, "maxItems").GetInt32());

        // scene.dialogue: minItems 1, maxItems 200
        var sceneDef = Prop(defs, "scene");
        var sceneProps = Prop(sceneDef, "properties");
        var dialogue = Prop(sceneProps, "dialogue");
        Assert.Equal(1, Prop(dialogue, "minItems").GetInt32());
        Assert.Equal(GamePackageValidator.MaxDialoguePerScene, Prop(dialogue, "maxItems").GetInt32());

        // scene.choices: maxItems 6（无 minItems，允许空数组）
        var choices = Prop(sceneProps, "choices");
        Assert.Equal(GamePackageValidator.MaxChoicesPerScene, Prop(choices, "maxItems").GetInt32());

        // choice.scoreDelta: number；正确性由独立 correct 字段表达
        var choiceDef = Prop(defs, "choice");
        var choiceProperties = Prop(choiceDef, "properties");
        var scoreDelta = Prop(choiceProperties, "scoreDelta");
        Assert.Equal("number", Prop(scoreDelta, "type").GetString());

        var answerKind = Prop(choiceProperties, "answerKind");
        Assert.Contains("CHOICE",
            Prop(answerKind, "enum").EnumerateArray()
                .Where(item => item.ValueKind == JsonValueKind.String)
                .Select(item => item.GetString()));
        _ = Prop(choiceProperties, "correct");
    }

    [Fact]
    public void Schema_EncodesEnumsForPurposeAndAssetType()
    {
        using var doc = LoadSchema();
        var defs = Prop(doc.RootElement, "$defs");

        var purpose = Prop(Prop(Prop(defs, "binding"), "properties"), "purpose");
        var purposeValues = Prop(purpose, "enum").EnumerateArray().Select(e => e.GetString()!).ToHashSet();
        Assert.Equal(new HashSet<string> { "EXPLAIN", "QUESTION", "FEEDBACK" }, purposeValues);

        var assetType = Prop(Prop(Prop(defs, "asset"), "properties"), "type");
        var typeValues = Prop(assetType, "enum").EnumerateArray().Select(e => e.GetString()!).ToHashSet();
        Assert.Equal(new HashSet<string> { "BACKGROUND", "CHARACTER", "AUDIO", "OTHER" }, typeValues);
    }

    [Fact]
    public void Schema_ForbidsAdditionalPropertiesAtEveryObject()
    {
        using var doc = LoadSchema();
        var root = doc.RootElement;
        // additionalProperties: false 表示禁止额外属性
        Assert.False(Prop(root, "additionalProperties").GetBoolean(), "根对象应禁止额外属性");

        var defs = Prop(root, "$defs");
        foreach (var name in new[] { "scene", "dialogueLine", "choice", "binding", "asset" })
        {
            var ap = Prop(defs, name).GetProperty("additionalProperties");
            Assert.False(ap.GetBoolean(), $"{name} 应禁止额外属性");
        }
    }
}
