package com.example.video_recorder

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EncoderUtil
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine

/** Pigeon calls [convert] on the main thread, which Transformer requires. */
@OptIn(UnstableApi::class)
class VideoRecorderPlugin : FlutterPlugin, HevcConverterHostApi {
  private class Conversion(
    val transformer: Transformer,
    val continuation: CancellableContinuation<ConversionReply>,
    val outputPath: String,
    val progressJob: Job,
  )

  private lateinit var context: Context
  private var flutterApi: HevcConverterFlutterApi? = null
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
  private val conversions = mutableMapOf<Long, Conversion>()

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    HevcConverterHostApi.setUp(binding.binaryMessenger, this)
    flutterApi = HevcConverterFlutterApi(binding.binaryMessenger)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    for (id in conversions.keys.toList()) cancel(id)
    HevcConverterHostApi.setUp(binding.binaryMessenger, null)
    flutterApi = null
    scope.cancel()
  }

  override suspend fun convert(request: ConversionRequest): ConversionReply {
    val inputMime = try {
      videoMimeType(request.inputPath)
    } catch (e: Exception) {
      throw HevcError("invalid_input", "Could not read the video: ${e.message}")
    } ?: throw HevcError("invalid_input", "The file has no video track.")

    if (inputMime == MimeTypes.VIDEO_H265) {
      return ConversionReply(NativeConversionStatus.ALREADY_HEVC, "The video is already HEVC.")
    }
    if (EncoderUtil.getSupportedEncoders(MimeTypes.VIDEO_H265).isEmpty()) {
      return ConversionReply(NativeConversionStatus.UNSUPPORTED, "This device has no HEVC encoder.")
    }

    File(request.outputPath).delete()
    return suspendCancellableCoroutine { continuation ->
      val transformer = buildTransformer(request)
      val progressJob = scope.launch { reportProgress(request.id, transformer) }
      conversions[request.id] =
        Conversion(transformer, continuation, request.outputPath, progressJob)
      continuation.invokeOnCancellation { cancel(request.id) }
      transformer.start(
        MediaItem.fromUri(Uri.fromFile(File(request.inputPath))),
        request.outputPath,
      )
    }
  }

  override fun cancel(id: Long) {
    val conversion = conversions.remove(id) ?: return
    conversion.progressJob.cancel()
    // Transformer doesn't call its listener after cancel(), so finish the
    // pending convert() here.
    conversion.transformer.cancel()
    File(conversion.outputPath).delete()
    if (conversion.continuation.isActive) {
      conversion.continuation.resume(ConversionReply(NativeConversionStatus.CANCELLED))
    }
  }

  private fun buildTransformer(request: ConversionRequest): Transformer {
    val id = request.id
    val encoderFactory = DefaultEncoderFactory.Builder(context)
      .setRequestedVideoEncoderSettings(
        VideoEncoderSettings.Builder().setBitrate(request.bitrate.toInt()).build(),
      )
      // Without this, Transformer silently falls back to H.264, which would
      // just re-encode the video in the same format at lower quality.
      .setEnableFallback(false)
      .build()

    return Transformer.Builder(context)
      .setVideoMimeType(MimeTypes.VIDEO_H265)
      .setEncoderFactory(encoderFactory)
      .addListener(object : Transformer.Listener {
        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
          val conversion = finish(id) ?: return
          if (exportResult.videoMimeType != MimeTypes.VIDEO_H265) {
            File(conversion.outputPath).delete()
            conversion.continuation.resume(
              ConversionReply(
                NativeConversionStatus.UNSUPPORTED,
                "The encoder produced ${exportResult.videoMimeType}.",
              ),
            )
            return
          }
          conversion.continuation.resume(ConversionReply(NativeConversionStatus.CONVERTED))
        }

        override fun onError(
          composition: Composition,
          exportResult: ExportResult,
          exportException: ExportException,
        ) {
          val conversion = finish(id) ?: return
          File(conversion.outputPath).delete()
          conversion.continuation.resumeWithException(
            HevcError(
              "conversion_failed",
              exportException.message ?: "Conversion failed.",
              exportException.errorCodeName,
            ),
          )
        }
      })
      .build()
  }

  private fun finish(id: Long): Conversion? =
    conversions.remove(id)?.also { it.progressJob.cancel() }

  private suspend fun reportProgress(id: Long, transformer: Transformer) {
    val holder = ProgressHolder()
    while (currentCoroutineContext().isActive) {
      if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
        try {
          flutterApi?.onProgress(id, holder.progress / 100.0)
        } catch (_: HevcError) {
          // Dart side gone (e.g. hot restart); the conversion carries on.
        }
      }
      delay(PROGRESS_INTERVAL_MS)
    }
  }

  private fun videoMimeType(path: String): String? {
    val extractor = MediaExtractor()
    try {
      extractor.setDataSource(path)
      for (i in 0 until extractor.trackCount) {
        val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
        if (mime?.startsWith("video/") == true) return mime
      }
      return null
    } finally {
      extractor.release()
    }
  }

  private companion object {
    const val PROGRESS_INTERVAL_MS = 200L
  }
}
