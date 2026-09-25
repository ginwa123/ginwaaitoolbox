package com.nalar.mobile.http

/** One header line. Kept as an ordered list so a replayed request keeps its original order. */
data class HttpHeader(val name: String, val value: String)

/** Everything needed to issue one call, independent of who issued it. */
data class HttpRequestSpec(
    val method: String,
    val url: String,
    val headers: List<HttpHeader> = emptyList(),
    val body: String? = null,
)

/** Seam so a replay can be verified without opening a socket. */
fun interface HttpExchange {
    fun execute(request: HttpRequestSpec): HttpResponseSpec
}

data class HttpResponseSpec(
    val statusCode: Int,
    val headers: List<HttpHeader> = emptyList(),
    val body: String? = null,
) {
    fun headerValues(name: String): List<String> =
        headers
            .filter { header -> header.name.equals(name, ignoreCase = true) }
            .map { header -> header.value }
}
