using System.Reflection.Emit;
using System.Text;
using System.Text.Json;
using Xunit;
using Xzawed.Keycloak.Admin;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// The two exception filters that classify an admin transport failure — <c>AdminClient.IsEncodingLookup</c> and
/// <c>BearerHandler.IsRefusedBody</c> — judged directly on the inputs the public path cannot produce: an exception never
/// thrown (no <c>TargetSite</c>) and one thrown from a method with no declaring type. Both helpers run only inside
/// <c>catch … when (…)</c> filters; an exception thrown inside a filter is swallowed and counts as false, so on the
/// production path the <c>?.</c> guards change no outcome — these tests pin each helper's own contract: false, and no throw.
/// </summary>
/// <remarks>
/// <para><c>IsEncodingLookup</c>: the judged exception is the one <c>Encoding.GetEncoding</c> threw (an inner one wrapped
/// by the transport included), so a unit test never builds one that was not thrown; a constructed-only inner exception ends
/// in false without a charset verdict.</para>
/// <para><c>IsRefusedBody</c>: a caught exception was thrown, so it has a <c>TargetSite</c>, and C# never emits a method
/// without a declaring type (a module-level function); both null sides end in false (not a refused request body).</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class ExceptionFilterInputTests
{
    private static T ThrownWithoutDeclaringType<T>(T ex) where T : Exception
    {
        var thrower = new DynamicMethod("Throw", typeof(void), new[] { typeof(Exception) }, typeof(ExceptionFilterInputTests).Module);
        var il = thrower.GetILGenerator();
        il.Emit(OpCodes.Ldarg_0);
        il.Emit(OpCodes.Throw);
        var run = (Action<Exception>)thrower.CreateDelegate(typeof(Action<Exception>));

        var caught = Assert.ThrowsAny<T>(() => run(ex));
        Assert.Same(ex, caught);
        // The precondition shape comes first: a runtime that gave this exception no TargetSite, or a declaring type, would
        // turn "no declaring type" into "never thrown" and leave the second null side unreached.
        Assert.NotNull(caught.TargetSite);
        Assert.Null(caught.TargetSite!.DeclaringType);
        return caught;
    }

    private static Exception Fresh(string kind) => kind switch
    {
        "json" => new JsonException(),
        "notsupported" => new NotSupportedException(),
        "argument" => new ArgumentException(),
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null),
    };

    [Fact]
    public void IsEncodingLookup_is_false_for_an_exception_never_thrown()
    {
        var ex = new ArgumentException("constructed only");
        Assert.Null(ex.TargetSite);
        Assert.False(AdminClient.IsEncodingLookup(ex));
    }

    [Fact]
    public void IsEncodingLookup_is_false_for_a_method_with_no_declaring_type() =>
        Assert.False(AdminClient.IsEncodingLookup(ThrownWithoutDeclaringType(new ArgumentException("x"))));

    [Fact]
    public void IsEncodingLookup_is_true_for_what_Encoding_GetEncoding_throws() =>
        Assert.True(AdminClient.IsEncodingLookup(Assert.Throws<ArgumentException>(() => Encoding.GetEncoding("no-such-charset"))));

    [Theory]
    [InlineData("json")]
    [InlineData("notsupported")]
    [InlineData("argument")]
    public void IsRefusedBody_is_false_for_a_serializer_exception_type_never_thrown(string kind)
    {
        var ex = Fresh(kind);
        Assert.Null(ex.TargetSite);
        Assert.False(BearerHandler.IsRefusedBody(ex));
    }

    [Theory]
    [InlineData("json")]
    [InlineData("notsupported")]
    [InlineData("argument")]
    public void IsRefusedBody_is_false_for_a_method_with_no_declaring_type(string kind) =>
        Assert.False(BearerHandler.IsRefusedBody(ThrownWithoutDeclaringType(Fresh(kind))));

    [Fact]
    public void IsRefusedBody_is_true_for_what_System_Text_Json_throws()
    {
        Assert.True(BearerHandler.IsRefusedBody(Assert.Throws<ArgumentException>(() => JsonSerializer.Serialize(double.NaN))));
        Assert.True(BearerHandler.IsRefusedBody(Assert.Throws<NotSupportedException>(() => JsonSerializer.Serialize(typeof(string)))));
    }
}
