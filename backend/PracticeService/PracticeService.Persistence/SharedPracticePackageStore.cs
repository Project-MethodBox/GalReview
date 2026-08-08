using Microsoft.Extensions.Configuration;
using MongoDB.Driver;
using MongoDB.Driver.GridFS;
using PracticeService.Application;
using PracticeService.Domain;

namespace PracticeService.Persistence;

public sealed class InMemorySharedPracticePackageStore : ISharedPracticePackageStore
{
    private readonly object _gate = new(); private readonly Dictionary<Guid, SharedPracticePackage> _metadata = []; private readonly Dictionary<Guid, byte[]> _content = [];
    public SharedPracticePackage Save(SharedPracticePackage package, byte[] content) { lock (_gate) { _metadata.Add(package.PackageId, package); _content.Add(package.PackageId, content.ToArray()); return package; } }
    public SharedPracticePackage? Get(Guid packageId) { lock (_gate) return _metadata.GetValueOrDefault(packageId); }
    public SharedPracticePackage? FindVersion(Guid owner, Guid project, string version) { lock (_gate) return _metadata.Values.FirstOrDefault(x => x.OwnerUserId == owner && x.SourceProjectId == project && x.Version == version); }
    public IReadOnlyList<SharedPracticePackage> Search(Guid requester, string? query, string? subject) { lock (_gate) return Filter(_metadata.Values, requester, query, subject); }
    public byte[]? ReadContent(Guid packageId) { lock (_gate) return _content.TryGetValue(packageId, out var value) ? value.ToArray() : null; }
    public void SaveMetadata(SharedPracticePackage package) { lock (_gate) _metadata[package.PackageId] = package; }
    internal static IReadOnlyList<SharedPracticePackage> Filter(IEnumerable<SharedPracticePackage> values, Guid requester, string? query, string? subject) => values
        .Where(x => x.WithdrawnAt is null && (x.Visibility == PackageVisibility.Public || x.OwnerUserId == requester))
        .Where(x => string.IsNullOrWhiteSpace(query) || x.Title.Contains(query.Trim(), StringComparison.OrdinalIgnoreCase))
        .Where(x => string.IsNullOrWhiteSpace(subject) || x.SubjectCode == subject).OrderByDescending(x => x.CreatedAt).Take(100).ToArray();
}

public sealed class MongoSharedPracticePackageStore : ISharedPracticePackageStore
{
    private readonly IMongoCollection<SharedPracticePackage> _metadata; private readonly GridFSBucket _bucket;
    public MongoSharedPracticePackageStore(IConfiguration configuration)
    {
        MongoMappings.EnsureRegistered();
        var client = new MongoClient(configuration.GetConnectionString("PracticeDatabase") ?? "mongodb://localhost:27017");
        var database = client.GetDatabase(configuration["MongoDb:Database"] ?? "qzwl_practice");
        _metadata = database.GetCollection<SharedPracticePackage>("shared_packages"); _bucket = new GridFSBucket(database, new GridFSBucketOptions { BucketName = "practice_packages" });
        _metadata.Indexes.CreateOne(new CreateIndexModel<SharedPracticePackage>(Builders<SharedPracticePackage>.IndexKeys.Ascending(x => x.OwnerUserId).Ascending(x => x.SourceProjectId).Ascending(x => x.Version), new CreateIndexOptions { Unique = true }));
    }
    public SharedPracticePackage Save(SharedPracticePackage package, byte[] content)
    { _bucket.UploadFromBytes(package.PackageId.ToString("D"), content); try { _metadata.InsertOne(package); return package; } catch { _bucket.Delete(_bucket.Find(Builders<GridFSFileInfo>.Filter.Eq(x => x.Filename, package.PackageId.ToString("D"))).First().Id); throw; } }
    public SharedPracticePackage? Get(Guid id) => _metadata.Find(x => x.PackageId == id).FirstOrDefault();
    public SharedPracticePackage? FindVersion(Guid owner, Guid project, string version) => _metadata.Find(x => x.OwnerUserId == owner && x.SourceProjectId == project && x.Version == version).FirstOrDefault();
    public IReadOnlyList<SharedPracticePackage> Search(Guid requester, string? query, string? subject) => InMemorySharedPracticePackageStore.Filter(_metadata.Find(Builders<SharedPracticePackage>.Filter.Empty).ToList(), requester, query, subject);
    public byte[]? ReadContent(Guid id) { try { return _bucket.DownloadAsBytesByName(id.ToString("D")); } catch (GridFSFileNotFoundException) { return null; } }
    public void SaveMetadata(SharedPracticePackage package)
    { var result = _metadata.ReplaceOne(x => x.PackageId == package.PackageId, package); if (!result.IsAcknowledged || result.MatchedCount != 1) throw new InvalidOperationException("Shared package update did not match."); }
}
