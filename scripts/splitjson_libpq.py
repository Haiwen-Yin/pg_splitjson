#!/usr/bin/env python3
"""Small libpq binding for managed tools; no third-party Python dependency.

Connection settings use standard libpq environment/conninfo. Never include
conninfo, password values, or arbitrary server error text in tool reports.
"""
import ctypes as c
import ctypes.util
import os


class DatabaseError(RuntimeError):
    def __init__(self, state, message):
        self.state = state
        super().__init__(f"PostgreSQL {state or 'connection'}: {message}")


_pq = c.CDLL(os.environ.get("PG_SPLITJSON_LIBPQ") or ctypes.util.find_library("pq"))


def _declare(name, restype, argtypes):
    fn = getattr(_pq, name)
    fn.restype, fn.argtypes = restype, argtypes
    return fn


_connect = _declare("PQconnectdb", c.c_void_p, [c.c_char_p])
_status = _declare("PQstatus", c.c_int, [c.c_void_p])
_finish = _declare("PQfinish", None, [c.c_void_p])
_exec = _declare("PQexec", c.c_void_p, [c.c_void_p, c.c_char_p])
_execparams = _declare("PQexecParams", c.c_void_p, [c.c_void_p, c.c_char_p, c.c_int,
                      c.c_void_p, c.POINTER(c.c_char_p), c.c_void_p, c.c_void_p, c.c_int])
_resultstatus = _declare("PQresultStatus", c.c_int, [c.c_void_p])
_errorfield = _declare("PQresultErrorField", c.c_char_p, [c.c_void_p, c.c_int])
_clear = _declare("PQclear", None, [c.c_void_p])
_ntuples = _declare("PQntuples", c.c_int, [c.c_void_p])
_nfields = _declare("PQnfields", c.c_int, [c.c_void_p])
_fname = _declare("PQfname", c.c_char_p, [c.c_void_p, c.c_int])
_isnull = _declare("PQgetisnull", c.c_int, [c.c_void_p, c.c_int, c.c_int])
_value = _declare("PQgetvalue", c.c_char_p, [c.c_void_p, c.c_int, c.c_int])


class Connection:
    def __init__(self, conninfo=""):
        self._connection = _connect(conninfo.encode())
        if not self._connection or _status(self._connection) != 0:
            self.close()
            raise DatabaseError(None, "connection failed (check libpq connection settings)")

    def close(self):
        if self._connection:
            _finish(self._connection)
            self._connection = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def execute(self, sql, params=None):
        if params is None:
            result = _exec(self._connection, sql.encode())
        else:
            encoded = [None if value is None else str(value).encode() for value in params]
            values = (c.c_char_p * len(encoded))(*encoded)
            result = _execparams(self._connection, sql.encode(), len(encoded), None, values, None, None, 0)
        if not result:
            raise DatabaseError(None, "query returned no result")
        try:
            if _resultstatus(result) not in (1, 2):
                state = _errorfield(result, ord("C"))
                # Do not leak arbitrary server details (replication DDL can
                # contain connection strings). SQLSTATE is sufficient to log.
                raise DatabaseError(state.decode() if state else None, "operation failed")
            names = [_fname(result, i).decode() for i in range(_nfields(result))]
            return [dict(zip(names, [None if _isnull(result, row, col) else _value(result, row, col).decode()
                                    for col in range(len(names))])) for row in range(_ntuples(result))]
        finally:
            _clear(result)


def identifier(name):
    """Quote a single identifier, never a SQL fragment."""
    return '"' + name.replace('"', '""') + '"'


def qualified(name):
    # PostgreSQL's parser should supply normalized name components to tools;
    # arbitrary regclass spelling must be sent as a SQL parameter instead.
    return '.'.join(identifier(part) for part in name)
