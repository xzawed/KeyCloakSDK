namespace Kc.Admin;

public sealed class Client : IDisposable
{
    private readonly UsersResource _users = new();

    public UsersResource Users => _users;

    public void Close()
    {
    }

    public void Dispose() => Close();

    public static class Defaults
    {
        public static readonly string[] Names = ["admin"];

        public static string First() => Names[0];
    }

    public sealed class UsersResource
    {
        public async Task<string> GetAsync(string id)
        {
            await Task.Yield();
            return id;
        }

        public Task DeleteAsync(string id) => Task.FromResult(id);
    }
}
