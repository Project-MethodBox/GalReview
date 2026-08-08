using Microsoft.Extensions.Configuration;
using MongoDB.Driver;
using PracticeService.Application;
using PracticeService.Domain;

namespace PracticeService.Persistence;

public sealed class InMemoryPracticeRepository : IPracticeRepository
{
    private readonly object _gate = new();
    private readonly Dictionary<Guid, StudyProject> _projects = [];
    private readonly Dictionary<Guid, PracticeQuestion> _questions = [];
    private readonly Dictionary<Guid, PracticeSession> _sessions = [];
    private readonly Dictionary<Guid, ExamPaper> _papers = [];
    private readonly Dictionary<Guid, PracticeJob> _jobs = [];
    public StudyProject CreateProject(StudyProject x) { lock (_gate) { _projects.Add(x.ProjectId, x); return x; } }
    public StudyProject? GetProject(Guid id) { lock (_gate) return _projects.GetValueOrDefault(id); }
    public IReadOnlyList<StudyProject> ListProjects(Guid owner) { lock (_gate) return _projects.Values.Where(x => x.OwnerUserId == owner).OrderByDescending(x => x.UpdatedAt).ToArray(); }
    public void SaveProject(StudyProject x) { lock (_gate) _projects[x.ProjectId] = x; }
    public PracticeQuestion CreateQuestion(PracticeQuestion x) { lock (_gate) { _questions.Add(x.QuestionId, x); return x; } }
    public PracticeQuestion? GetQuestion(Guid id) { lock (_gate) return _questions.GetValueOrDefault(id); }
    public IReadOnlyList<PracticeQuestion> ListQuestions(Guid project) { lock (_gate) return _questions.Values.Where(x => x.ProjectId == project).OrderBy(x => x.CreatedAt).ToArray(); }
    public void SaveQuestion(PracticeQuestion x) { lock (_gate) _questions[x.QuestionId] = x; }
    public PracticeSession CreateSession(PracticeSession x) { lock (_gate) { _sessions.Add(x.SessionId, x); return x; } }
    public PracticeSession? GetSession(Guid id) { lock (_gate) return _sessions.GetValueOrDefault(id); }
    public void SaveSession(PracticeSession x) { lock (_gate) _sessions[x.SessionId] = x; }
    public ExamPaper CreateExamPaper(ExamPaper x) { lock (_gate) { _papers.Add(x.ExamPaperId, x); return x; } }
    public ExamPaper? GetExamPaper(Guid id) { lock (_gate) return _papers.GetValueOrDefault(id); }
    public PracticeJob CreateJob(PracticeJob x) { lock (_gate) { _jobs.Add(x.JobId, x); return x; } }
    public PracticeJob? GetJob(Guid id) { lock (_gate) return _jobs.GetValueOrDefault(id); }
    public PracticeJob? FindJob(Guid owner, Guid project, Guid key) { lock (_gate) return _jobs.Values.FirstOrDefault(x => x.OwnerUserId == owner && x.ProjectId == project && x.IdempotencyKey == key); }
    public void SaveJob(PracticeJob x) { lock (_gate) _jobs[x.JobId] = x; }
}

public sealed class MongoPracticeRepository : IPracticeRepository
{
    private readonly IMongoCollection<StudyProject> _projects;
    private readonly IMongoCollection<PracticeQuestion> _questions;
    private readonly IMongoCollection<PracticeSession> _sessions;
    private readonly IMongoCollection<ExamPaper> _papers;
    private readonly IMongoCollection<PracticeJob> _jobs;
    public MongoPracticeRepository(IConfiguration configuration)
    {
        MongoMappings.EnsureRegistered();
        var connection = configuration.GetConnectionString("PracticeDatabase") ?? "mongodb://localhost:27017";
        var db = new MongoClient(connection).GetDatabase(configuration["MongoDb:Database"] ?? "qzwl_practice");
        _projects = db.GetCollection<StudyProject>("projects"); _questions = db.GetCollection<PracticeQuestion>("questions");
        _sessions = db.GetCollection<PracticeSession>("sessions"); _papers = db.GetCollection<ExamPaper>("exam_papers");
        _jobs = db.GetCollection<PracticeJob>("jobs");
        _projects.Indexes.CreateOne(new CreateIndexModel<StudyProject>(Builders<StudyProject>.IndexKeys.Ascending(x => x.OwnerUserId).Descending(x => x.UpdatedAt)));
        _questions.Indexes.CreateOne(new CreateIndexModel<PracticeQuestion>(Builders<PracticeQuestion>.IndexKeys.Ascending(x => x.ProjectId).Ascending(x => x.Status)));
        _sessions.Indexes.CreateOne(new CreateIndexModel<PracticeSession>(Builders<PracticeSession>.IndexKeys.Ascending(x => x.OwnerUserId).Descending(x => x.CreatedAt)));
        _jobs.Indexes.CreateOne(new CreateIndexModel<PracticeJob>(Builders<PracticeJob>.IndexKeys.Ascending(x => x.OwnerUserId).Ascending(x => x.ProjectId).Ascending(x => x.IdempotencyKey), new CreateIndexOptions { Unique = true }));
    }
    public StudyProject CreateProject(StudyProject x) { _projects.InsertOne(x); return x; }
    public StudyProject? GetProject(Guid id) => _projects.Find(x => x.ProjectId == id).FirstOrDefault();
    public IReadOnlyList<StudyProject> ListProjects(Guid owner) => _projects.Find(x => x.OwnerUserId == owner).SortByDescending(x => x.UpdatedAt).ToList();
    public void SaveProject(StudyProject x) => Replace(_projects, y => y.ProjectId == x.ProjectId, x);
    public PracticeQuestion CreateQuestion(PracticeQuestion x) { _questions.InsertOne(x); return x; }
    public PracticeQuestion? GetQuestion(Guid id) => _questions.Find(x => x.QuestionId == id).FirstOrDefault();
    public IReadOnlyList<PracticeQuestion> ListQuestions(Guid project) => _questions.Find(x => x.ProjectId == project).SortBy(x => x.CreatedAt).ToList();
    public void SaveQuestion(PracticeQuestion x) => Replace(_questions, y => y.QuestionId == x.QuestionId, x);
    public PracticeSession CreateSession(PracticeSession x) { _sessions.InsertOne(x); return x; }
    public PracticeSession? GetSession(Guid id) => _sessions.Find(x => x.SessionId == id).FirstOrDefault();
    public void SaveSession(PracticeSession x) => Replace(_sessions, y => y.SessionId == x.SessionId, x);
    public ExamPaper CreateExamPaper(ExamPaper x) { _papers.InsertOne(x); return x; }
    public ExamPaper? GetExamPaper(Guid id) => _papers.Find(x => x.ExamPaperId == id).FirstOrDefault();
    public PracticeJob CreateJob(PracticeJob x) { _jobs.InsertOne(x); return x; }
    public PracticeJob? GetJob(Guid id) => _jobs.Find(x => x.JobId == id).FirstOrDefault();
    public PracticeJob? FindJob(Guid owner, Guid project, Guid key) => _jobs.Find(x => x.OwnerUserId == owner && x.ProjectId == project && x.IdempotencyKey == key).FirstOrDefault();
    public void SaveJob(PracticeJob x) => Replace(_jobs, y => y.JobId == x.JobId, x);
    private static void Replace<T>(IMongoCollection<T> collection, System.Linq.Expressions.Expression<Func<T, bool>> filter, T value)
    {
        var result = collection.ReplaceOne(filter, value);
        if (!result.IsAcknowledged || result.MatchedCount != 1) throw new InvalidOperationException("MongoDB update did not match the expected aggregate.");
    }
}
