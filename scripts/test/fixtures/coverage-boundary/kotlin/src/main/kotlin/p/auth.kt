package p

public class AuthClient internal constructor(private val url: String) {
    public suspend fun token(): String = "class X { ${url.length} } fun y()"

    private companion object {
        val RAW = """
            val notTopLevel = 1
        """
    }
}
