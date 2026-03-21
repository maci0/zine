Stub functions are plain C-callable functions. They receive host-accessible pointers. They return host-accessible pointers. They never
translate addresses. They never check what platform they’re on. The thunk/boundary layer handles ALL translation, width conversion,
and address space mapping.
