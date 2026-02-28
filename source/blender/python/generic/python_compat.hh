/* SPDX-FileCopyrightText: 2023 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup pygen
 * \brief header-only compatibility defines.
 *
 * \note this header should not be removed/cleaned where Python is used.
 * Because its required for Blender to build against different versions of Python.
 */

#pragma once

#include <Python.h>

/* This code is not placed in the blender namespace, as it is meant to replace Python functions
 * in the global namespace. */

/* Python 3.13 added PyLong_AsInt; use internal fallback for older versions. */
#if PY_VERSION_HEX < 0x030D0000
#  ifndef PyLong_AsInt
#    define PyLong_AsInt _PyLong_AsInt
#  endif
#endif

/* Python 3.13 added PyWeakref_GetRef(obj, *result) -> int.
 * Python 3.11 has PyWeakref_GetObject(ref) -> PyObject*. */
#if PY_VERSION_HEX < 0x030d0000
static inline int PyWeakref_GetRef(PyObject *ref, PyObject **pobj)
{
  PyObject *obj = PyWeakref_GetObject(ref);
  if (obj == nullptr) {
    return -1;
  }
  if (obj == Py_None) {
    *pobj = nullptr;
    return 0;
  }
  Py_INCREF(obj);
  *pobj = obj;
  return 1;
}
#endif

/* Python 3.13 added PyObject_GetOptionalAttr / PyObject_GetOptionalAttrString.
 * Provide shims using PyObject_GetAttr for older versions. */
#if PY_VERSION_HEX < 0x030d0000
static inline int PyObject_GetOptionalAttr(PyObject *obj, PyObject *name, PyObject **result)
{
  PyObject *val = PyObject_GetAttr(obj, name);
  if (val != nullptr) {
    *result = val;
    return 1;
  }
  if (PyErr_ExceptionMatches(PyExc_AttributeError)) {
    PyErr_Clear();
    *result = nullptr;
    return 0;
  }
  *result = nullptr;
  return -1;
}

static inline int PyObject_GetOptionalAttrString(PyObject *obj, const char *name, PyObject **result)
{
  PyObject *key = PyUnicode_FromString(name);
  if (key == nullptr) {
    *result = nullptr;
    return -1;
  }
  int ret = PyObject_GetOptionalAttr(obj, key, result);
  Py_DECREF(key);
  return ret;
}
#endif

/* Python 3.13 added PyDict_Pop(dict, key, *result) -> int.
 * Python 3.11 has _PyDict_Pop(dict, key, default) -> PyObject*. */
#if PY_VERSION_HEX < 0x030d0000
static inline int PyDict_Pop(PyObject *dict, PyObject *key, PyObject **result)
{
  PyObject *val = _PyDict_Pop(dict, key, Py_None);
  if (val == nullptr) {
    return -1;
  }
  if (val == Py_None) {
    Py_DECREF(val);
    *result = nullptr;
    return 0;
  }
  *result = val;
  return 1;
}
#endif

/* Python 3.14 made some changes, use the "new" names. */
#if PY_VERSION_HEX < 0x030e0000
#  define Py_HashPointer _Py_HashPointer
#  define PyThreadState_GetUnchecked _PyThreadState_UncheckedGet
/* TODO: Support: `PyDict_Pop`, it has different arguments. */
#endif

/* _PyArg_CheckPositional is a macro in Python < 3.14, only declare as function for 3.14+. */
#if PY_VERSION_HEX >= 0x030e0000
int _PyArg_CheckPositional(const char *name, Py_ssize_t nargs, Py_ssize_t min, Py_ssize_t max);
#endif
