
# C types

cdef struct _core_event:
    _core_event *prev
    _core_event *next
    int is_log
    int level
    void *data
    int len

cdef struct _handler:
    _handler *next
    _handler *prev
    int func(object obj) except -1
    void *obj

cdef struct _handler_queue:
    _handler *head
    _handler *tail

# callback functions

cdef void _cb_log(int level, char_ptr_const data, int len) noexcept:
    cdef _core_event *event
    event = <_core_event *> malloc(sizeof(_core_event))
    if event != NULL:
        event.data = malloc(len)
        if event.data == NULL:
            free(event)
            return
        event.is_log = 1
        event.level = level
        memcpy(event.data, data, len)
        event.len = len
        if _event_queue_append(event) != 0:
            free(event.data)
            free(event)

# functions

cdef int _add_event(object event_name, dict params) except -1:
    cdef tuple data
    cdef _core_event *event
    cdef int status
    event = <_core_event *> malloc(sizeof(_core_event))
    if event == NULL:
        raise MemoryError()
    data = (event_name, params)
    event.is_log = 0
    event.data = <void *> data
    status = _event_queue_append(event)
    if status != 0:
        raise PJSIPError("Could not obtain lock", status)
    Py_INCREF(data)
    return 0

cdef int _event_queue_append(_core_event *event):
    global _event_queue_head, _event_queue_tail, _event_queue_lock
    cdef int locked = 0, status
    event.next = NULL
    if _event_queue_lock != NULL:
        status = pj_mutex_lock(_event_queue_lock)
        if status != 0:
            return status
        locked = 1
    if _event_queue_head == NULL:
        event.prev = NULL
        _event_queue_head = event
        _event_queue_tail = event
    else:
        _event_queue_tail.next = event
        event.prev = _event_queue_tail
        _event_queue_tail = event
    if locked:
        pj_mutex_unlock(_event_queue_lock)
    return 0

cdef list _get_clear_event_queue():
    global _re_log, _event_queue_head, _event_queue_tail, _event_queue_lock
    cdef object events = []
    cdef _core_event *event
    cdef _core_event *event_free
    cdef object event_tup
    cdef object event_params, log_msg, log_match
    cdef int locked = 0
    if _event_queue_lock != NULL:
        status = pj_mutex_lock(_event_queue_lock)
        if status != 0:
            return status
        locked = 1
    event = _event_queue_head
    _event_queue_head = _event_queue_tail = NULL
    if locked:
        pj_mutex_unlock(_event_queue_lock)
    while event != NULL:
        if event.is_log:
            log_msg = _pj_buf_len_to_str(<char *> event.data, event.len)
            event_params = dict(level=event.level, message=log_msg)
            events.append(("SIPEngineLog", event_params))
        else:
            event_tup = <object> event.data
            Py_DECREF(event_tup)
            events.append(event_tup)
        event_free = event
        event = event.next
        free(event_free)
    return events

cdef int _add_handler(int func(object obj) except -1, object obj, _handler_queue *queue) except -1:
    cdef _handler *handler
    handler = <_handler *> malloc(sizeof(_handler))
    if handler == NULL:
        raise MemoryError()
    handler.func = func
    handler.obj = <void *> obj
    handler.next = NULL
    if queue.head == NULL:
        handler.prev = NULL
        queue.head = handler
        queue.tail = handler
    else:
        queue.tail.next = handler
        handler.prev = queue.tail
        queue.tail = handler
    return 0

cdef int _remove_handler(object obj, _handler_queue *queue) except -1:
    cdef _handler *handler
    cdef _handler *handler_free
    handler = queue.head
    while handler != NULL:
        if handler.obj == <void *> obj:
            if handler.prev != NULL:
                handler.prev.next = handler.next
            if handler.next != NULL:
                handler.next.prev = handler.prev
            if queue.head == handler:
                queue.head = handler.next
            if queue.tail == handler:
                queue.tail = handler.prev
            handler_free = handler
            handler = handler.next
            free(handler_free)
        else:
            handler = handler.next
    return 0

cdef int _process_handler_queue(PJSIPUA ua, _handler_queue *queue) except -1:
    cdef _handler *handler
    cdef _handler *handler_free
    handler = queue.head
    queue.head = queue.tail = NULL
    while handler != NULL:
        try:
            handler.func(<object> handler.obj)
        except:
            ua._handle_exception(1)
        handler_free = handler
        handler = handler.next
        free(handler_free)
    return 0

# globals

cdef pj_mutex_t *_event_queue_lock = NULL
cdef _core_event *_event_queue_head = NULL
cdef _core_event *_event_queue_tail = NULL
cdef _handler_queue _post_poll_handler_queue
_post_poll_handler_queue.head = NULL
_post_poll_handler_queue.tail = NULL
cdef _handler_queue _dealloc_handler_queue
_dealloc_handler_queue.head = NULL
_dealloc_handler_queue.tail = NULL
