// ============================================================================
// GalGameService 固定剧情 Mock
//
// 仅在 GalGameMock:UseFixedStory=true 时使用。剧情只用于本地演示：不产生
// QUESTION 绑定或学习证据，也不会改写真实 KnowledgeService 的知识与掌握度。
// ============================================================================

public static class MockStoryPackageFactory
{
    private const string GeneratorVersion = "gala-0.1.0";
    private static readonly Guid TargetPointId = Guid.Parse("d1adc45a-52db-4de2-9cf7-02e1ac0d53cb");
    private static readonly Guid PrerequisitePointId = Guid.Parse("84f7d873-e573-4689-b18d-6f82c745d1bf");

    private static readonly Guid[] NavigationIds =
    [
        Guid.Parse("a75b4e20-2f8a-4d26-9d93-3d4e58caed8d"),
        Guid.Parse("6a9b523b-9238-4b94-9220-0dbf860ebdea"),
        Guid.Parse("e8a66fc2-d0a1-4d7c-8b6d-3f6b09898434"),
        Guid.Parse("c7d352cf-8d0f-4b0e-8cb7-5d7d11c14d2e"),
        Guid.Parse("b9d7d92c-227d-4af1-9706-cd6d6b4fc3b8"),
        Guid.Parse("1da7bd3f-1957-4bdb-986a-b4bc5e3f70e5"),
    ];

    public static GamePackage Create(GameGenerationRequest request)
    {
        var scenes = new Scene[]
        {
            StoryScene("scene-001", "雾岚町的夏祭前夜", TargetPointId, NavigationIds[0],
                new[]
                {
                    Narration("夏祭前夜，旧校舍屋檐下的风铃又响了。", "mysterious"),
                    LinWan("苏晴，陪学姐走一趟吧？一个人来这里，总觉得太安静了。", "shy"),
                    SuQing("学姐明明是想见我，却偏要拿风铃当借口。好吧，我陪你。", "playful"),
                }, "接过笔记，和林晚学姐一起出发", "scene-002", KnowledgePurpose.FEEDBACK),
            StoryScene("scene-002", "被雨洗亮的温室", PrerequisitePointId, NavigationIds[1],
                new[]
                {
                    Narration("温室里的稻苗比昨天更密，林晚俯身示意苏晴看叶片间留下的空隙。", "thoughtful"),
                    LinWan("第一个主题是群体与个体：数量太多会争夺资源，太少又难以形成理想群体。", "explaining"),
                    SuQing("所以什么都不能只看一面？包括学姐每次靠近我时，故作镇定的表情？", "teasing"),
                }, "记下群体与个体的关系", "scene-003", KnowledgePurpose.EXPLAIN),
            StoryScene("scene-003", "长廊尽头的叶龄刻度", TargetPointId, NavigationIds[2],
                new[]
                {
                    Narration("长廊的玻璃窗蒙着水汽，笔记上的第二个提示是：叶龄与分蘖。", "calm"),
                    LinWan("观察叶龄能帮助判断分蘖进程，管理不能只凭感觉，也要看生长节奏。", "explaining"),
                    SuQing("雨停了。学姐，我们是不是也该……往前一点？", "warm"),
                }, "沿着长廊继续寻找线索", "scene-004", KnowledgePurpose.EXPLAIN),
            StoryScene("scene-004", "月光落进通风窗", PrerequisitePointId, NavigationIds[3],
                new[]
                {
                    Narration("第三个提示藏在温室通风窗后：透光与通风会改变群体内部的小气候。", "curious"),
                    LinWan("光照、空气和湿度并不是背景，它们会让每一株苗获得不同的生长条件。", "explaining"),
                    SuQing("幸好我在？那我以后是不是该一直站在学姐身边，帮你按住所有会飞走的东西？", "bashful"),
                }, "替她按住快被风吹走的纸页", "scene-005", KnowledgePurpose.EXPLAIN),
            StoryScene("scene-005", "神社石阶上的水纹", TargetPointId, NavigationIds[4],
                new[]
                {
                    Narration("石阶尽头是小小的水池，愿签背面写着第四个主题：肥水协调。", "mysterious"),
                    LinWan("养分和水分需要配合，过量或失衡都会打乱原本稳定的生长节奏。", "explaining"),
                    SuQing("照顾一片田，和照顾重要的人一样，都不能只靠一时冲动。学姐听懂了吗？", "soft"),
                }, "和她一起读完愿签背面的提示", "scene-006", KnowledgePurpose.EXPLAIN),
            StoryScene("scene-006", "萤火照见的分蘖田", PrerequisitePointId, NavigationIds[5],
                new[]
                {
                    Narration("田埂边的萤火虫一闪一闪，第五个主题指向无效分蘖的控制。", "dreamy"),
                    LinWan("并不是每一次分枝都能结出同样的收获；适时调节，才能把资源留给更有价值的生长。", "explaining"),
                    SuQing("我知道。学姐想说的，是把最珍贵的时间留给真正重要的人……比如我吗？", "playful"),
                }, "跟着萤火，走向最后的灯火", "scene-007", KnowledgePurpose.EXPLAIN),
            StoryScene("scene-007", "风铃下的最后一页", TargetPointId, NavigationIds[0],
                new[]
                {
                    Narration("第六和第七个主题终于并排出现：穗数、粒数与产量构成，以及分蘖期的管理目标。", "serious"),
                    LinWan("前面的观察最终都会汇向同一件事——协调群体数量与个体生长，形成合理的群体结构。", "explaining"),
                    SuQing("谜题解开了。至于明天的夏祭……如果学姐亲自邀请，我当然会来。", "hopeful"),
                }, "答应明晚再来听风铃", "scene-008", KnowledgePurpose.FEEDBACK),
            new(
                SceneId: "scene-008",
                Title: "夏祭的第一盏灯",
                Dialogue: new DialogueLine[]
                {
                    Narration("远处的灯笼一盏盏亮起，旧笔记上的字迹也在暮色里慢慢安静下来。", "warm"),
                    LinWan("这次就当作我们之间的秘密。苏晴，别让其他人知道我今天有多高兴。", "bashful"),
                    SuQing("那学姐要记得，明天也只许和我一起听风铃。", "smile"),
                },
                Choices: Array.Empty<Choice>(),
                KnowledgeBindings: Array.Empty<KnowledgeBinding>()),
        };

        return new GamePackage("1.0", Guid.NewGuid(), GeneratorVersion, request.ReviewPlanId,
            request.SnapshotVersion, scenes[0].SceneId, scenes, Array.Empty<AssetRef>());
    }

    private static DialogueLine Narration(string text, string emotion) => new("旁白", text, emotion);
    private static DialogueLine LinWan(string text, string emotion) => new("林晚", text, emotion);
    private static DialogueLine SuQing(string text, string emotion) => new("苏晴", text, emotion);

    private static Scene StoryScene(
        string sceneId, string title, Guid pointId, Guid navigationId, DialogueLine[] dialogue,
        string choiceText, string nextSceneId, KnowledgePurpose purpose) => new(
            sceneId,
            title,
            dialogue.Select((line, index) => index == 0
                ? new DialogueLine("旁白", line.Text, line.Emotion)
                : line).ToArray(),
            new[] { new Choice($"c-{sceneId}-1", navigationId, choiceText, nextSceneId, 0, pointId) },
            new[] { new KnowledgeBinding(pointId, navigationId, purpose) });
}
