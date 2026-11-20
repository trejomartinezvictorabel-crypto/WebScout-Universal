package com.webscout.webscout_universal

import android.app.Activity
import android.app.DownloadManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val channelName = "webscout/native"
    private val pickCode = 4711
    private var pendingPick: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    handle(call, result)
                } catch (e: Exception) {
                    result.error("native", e.message ?: e.toString(), null)
                }
            }
    }

    @Suppress("DEPRECATION")
    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Selector de carpeta SAF (almacenamiento interno, microSD, Descargas...)
            "pickFolder" -> {
                if (pendingPick != null) {
                    result.error("busy", "Ya hay un selector abierto", null)
                    return
                }
                pendingPick = result
                val i = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                i.addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
                )
                startActivityForResult(i, pickCode)
            }

            // Descarga nativa reanudable (HTTP Range + notificación de progreso).
            "enqueue" -> {
                val url = call.argument<String>("url")!!
                val name = call.argument<String>("name")!!
                val ua = call.argument<String>("ua")
                val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                val req = DownloadManager.Request(Uri.parse(url))
                    .setTitle(name)
                    .setDescription("WebScout · descarga reanudable")
                    .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                    .setAllowedOverMetered(true)
                    .setAllowedOverRoaming(true)
                    .setDestinationInExternalFilesDir(
                        this,
                        Environment.DIRECTORY_DOWNLOADS,
                        "webscout/" + System.currentTimeMillis() + "_" + name
                    )
                if (ua != null) req.addRequestHeader("User-Agent", ua)
                result.success(dm.enqueue(req))
            }

            "query" -> {
                val id = call.argument<Number>("id")!!.toLong()
                val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                val c = dm.query(DownloadManager.Query().setFilterById(id))
                val m = HashMap<String, Any?>()
                if (c != null && c.moveToFirst()) {
                    m["status"] = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                    m["reason"] = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
                    m["downloaded"] = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                    m["total"] = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
                    m["local"] = c.getString(c.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_FILENAME))
                } else {
                    m["status"] = -1
                }
                c?.close()
                result.success(m)
            }

            "cancel" -> {
                val id = call.argument<Number>("id")!!.toLong()
                val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                dm.remove(id)
                result.success(true)
            }

            "deleteTemp" -> {
                val path = call.argument<String>("path")!!
                result.success(File(path).delete())
            }

            // Copia en streaming a Descargas (MediaStore, sin permisos de almacenamiento).
            "saveToDownloads" -> {
                val path = call.argument<String>("path")!!
                val name = call.argument<String>("name")!!
                val mime = call.argument<String>("mime") ?: "application/octet-stream"
                thread {
                    try {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                            throw Exception("Se requiere Android 10 o superior")
                        }
                        val values = ContentValues().apply {
                            put(MediaStore.Downloads.DISPLAY_NAME, name)
                            put(MediaStore.Downloads.MIME_TYPE, mime)
                            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                            put(MediaStore.Downloads.IS_PENDING, 1)
                        }
                        val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                            ?: throw Exception("No se pudo crear el archivo en Descargas")
                        contentResolver.openOutputStream(uri)!!.use { out ->
                            FileInputStream(File(path)).use { it.copyTo(out, 256 * 1024) }
                        }
                        val done = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
                        contentResolver.update(uri, done, null, null)
                        runOnUiThread { result.success("Descargas/$name") }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("save", e.message ?: e.toString(), null) }
                    }
                }
            }

            // Copia en streaming a la carpeta elegida con SAF (interna o microSD).
            "saveToTree" -> {
                val path = call.argument<String>("path")!!
                val tree = call.argument<String>("tree")!!
                val name = call.argument<String>("name")!!
                val mime = call.argument<String>("mime") ?: "application/octet-stream"
                thread {
                    try {
                        val treeUri = Uri.parse(tree)
                        val parent = DocumentsContract.buildDocumentUriUsingTree(
                            treeUri, DocumentsContract.getTreeDocumentId(treeUri)
                        )
                        val doc = DocumentsContract.createDocument(contentResolver, parent, mime, name)
                            ?: throw Exception("No se pudo crear el archivo en la carpeta elegida")
                        contentResolver.openOutputStream(doc, "w")!!.use { out ->
                            FileInputStream(File(path)).use { it.copyTo(out, 256 * 1024) }
                        }
                        runOnUiThread { result.success(doc.toString()) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("save", e.message ?: e.toString(), null) }
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == pickCode) {
            val r = pendingPick
            pendingPick = null
            val uri = data?.data
            if (resultCode == Activity.RESULT_OK && uri != null) {
                try {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                } catch (e: Exception) {
                    // El permiso de la sesión actual basta para guardar ahora.
                }
                r?.success(uri.toString())
            } else {
                r?.success(null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
