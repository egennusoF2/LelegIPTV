/**
 * mpegts.js loader for Astro dev: fetches via /__stream proxy (same-origin, UA/referer).
 */
import { wrapStreamUrlForDev, devProxyFetchHeaders } from "@/scripts/lib/stream-proxy"
import { log } from "@/scripts/lib/log.js"

const LoaderStatus = {
  kIdle: 0,
  kConnecting: 1,
  kBuffering: 2,
  kError: 3,
  kComplete: 4,
}

const LoaderErrors = {
  EXCEPTION: "Exception",
  HTTP_STATUS_CODE_INVALID: "HttpStatusCodeInvalid",
}

function isLoopbackMediaProxyUrl(url) {
  try {
    const parsed = new URL(url)
    return (
      (parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost") &&
      /^\/__(?:transcode|stream)\b/.test(parsed.pathname)
    )
  } catch {
    return false
  }
}

/** @param {(url: string) => Headers} getBaseHeaders */
export function createMpegtsDevProxyLoader(getBaseHeaders) {
  class DevProxyStreamLoader {
    constructor(seekHandler, config) {
      this._seekHandler = seekHandler
      this._config = config || {}
      this._type = "dev-proxy-stream-loader"
      this._status = LoaderStatus.kIdle
      this._needStash = true
      this._onContentLengthKnown = null
      this._onURLRedirect = null
      this._onDataArrival = null
      this._onError = null
      this._onComplete = null
      this._requestAbort = false
      this._abortController = null
      this._contentLength = null
      this._receivedLength = 0
      this._range = null
      this._getBaseHeaders = getBaseHeaders
    }

    static isSupported() {
      return typeof ReadableStream !== "undefined"
    }

    destroy() {
      if (this.isWorking()) this.abort()
      this._onContentLengthKnown = null
      this._onURLRedirect = null
      this._onDataArrival = null
      this._onError = null
      this._onComplete = null
    }

    isWorking() {
      return (
        this._status === LoaderStatus.kConnecting ||
        this._status === LoaderStatus.kBuffering
      )
    }

    get type() {
      return this._type
    }
    get status() {
      return this._status
    }
    get needStashBuffer() {
      return this._needStash
    }

    get onContentLengthKnown() {
      return this._onContentLengthKnown
    }
    set onContentLengthKnown(cb) {
      this._onContentLengthKnown = cb
    }
    get onURLRedirect() {
      return this._onURLRedirect
    }
    set onURLRedirect(callback) {
      this._onURLRedirect = callback
    }
    get onDataArrival() {
      return this._onDataArrival
    }
    set onDataArrival(cb) {
      this._onDataArrival = cb
    }
    get onError() {
      return this._onError
    }
    set onError(cb) {
      this._onError = cb
    }
    get onComplete() {
      return this._onComplete
    }
    set onComplete(cb) {
      this._onComplete = cb
    }

    open(dataSource, range) {
      this._dataSource = dataSource
      this._range = range || { from: 0 }
      this._receivedLength = 0
      this._requestAbort = false

      let sourceURL = dataSource.url
      if (this._config.reuseRedirectedURL && dataSource.redirectedURL != null) {
        sourceURL = dataSource.redirectedURL
      }

      const seekConfig = this._seekHandler.getConfig(sourceURL, range)
      const loopbackProxy = isLoopbackMediaProxyUrl(seekConfig.url)
      const mediaHeaders = loopbackProxy ? new Headers() : this._getBaseHeaders(seekConfig.url)
      const proxyUrl = loopbackProxy ? seekConfig.url : wrapStreamUrlForDev(seekConfig.url)
      const params = {
        method: "GET",
        headers: loopbackProxy ? mediaHeaders : devProxyFetchHeaders(mediaHeaders),
      }

      if (typeof AbortController !== "undefined") {
        this._abortController = new AbortController()
        params.signal = this._abortController.signal
      }

      this._status = LoaderStatus.kConnecting
      if (loopbackProxy) {
        log.info("[xt:mpegts-dev-loader] loopback fetch", proxyUrl.replace(/url=[^&]+/, "url=***"))
      }
      fetch(proxyUrl, params)
        .then((res) => {
          if (this._requestAbort) {
            this._status = LoaderStatus.kIdle
            res.body?.cancel?.()
            return
          }
          if (res.ok && res.status >= 200 && res.status <= 299) {
            const lengthHeader = res.headers.get("Content-Length")
            if (lengthHeader != null) {
              this._contentLength = parseInt(lengthHeader, 10)
              if (this._contentLength !== 0 && this._onContentLengthKnown) {
                this._onContentLengthKnown(this._contentLength)
              }
            }
            const reader = res.body?.getReader?.()
            if (!reader) {
              this._status = LoaderStatus.kError
              this._onError?.(LoaderErrors.EXCEPTION, {
                code: -1,
                msg: "Response body is not readable",
              })
              return
            }
            return this._pump(reader)
          }
          this._status = LoaderStatus.kError
          this._onError?.(LoaderErrors.HTTP_STATUS_CODE_INVALID, {
            code: res.status,
            msg: res.statusText,
          })
        })
        .catch((e) => {
          if (this._abortController?.signal?.aborted) return
          this._status = LoaderStatus.kError
          this._onError?.(LoaderErrors.EXCEPTION, {
            code: -1,
            msg: String(e?.message || e),
          })
        })
    }

    abort() {
      this._requestAbort = true
      try {
        this._abortController?.abort()
      } catch {}
    }

    _pump(reader) {
      return reader.read().then((result) => {
        if (result.done) {
          this._status = LoaderStatus.kComplete
          const from = this._range?.from ?? 0
          this._onComplete?.(from, from + this._receivedLength - 1)
          return
        }
        if (this._requestAbort || this._abortController?.signal?.aborted) {
          this._status = LoaderStatus.kComplete
          return reader.cancel?.()
        }
        this._status = LoaderStatus.kBuffering
        const value = result.value
        const chunk =
          value.byteOffset === 0 && value.byteLength === value.buffer.byteLength
            ? value.buffer
            : value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength)
        const byteStart = (this._range?.from ?? 0) + this._receivedLength
        this._receivedLength += chunk.byteLength
        this._onDataArrival?.(chunk, byteStart, this._receivedLength)
        return this._pump(reader)
      })
    }
  }

  return DevProxyStreamLoader
}
