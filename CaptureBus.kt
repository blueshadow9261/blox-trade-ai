package com.bloxtrade.capture

/** Service -> plugin event channel. */
object CaptureBus {
    @Volatile var listener: ((String, String) -> Unit)? = null
    fun emit(signal: String, arg: String) { listener?.invoke(signal, arg) }
}
