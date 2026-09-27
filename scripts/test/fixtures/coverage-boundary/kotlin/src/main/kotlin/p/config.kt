package p

public data class Config(val url: String)

public fun defaultConfig(): Config = Config(AuthClient::class.java.name)
