namespace Kc;

// Outside the boundary (coverlet.runsettings excludes Kc.AuthClient only): the unit-unreached ledger does not list it.
public sealed record Config(string ServerUrl, string Realm)
{
    public bool Valid() => ServerUrl.Length > 0 && Realm.Length > 0;
}
