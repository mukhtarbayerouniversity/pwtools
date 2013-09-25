"""numpy.testing like functions for usage in tests. We also have tools to
compare nested dictionaries containing numpy arrays etc.

The following functions are defined:

array_equal
all_types_no_dict_equal
dict_with_all_types_equal
all_types_equal

array_almost_equal
all_types_no_dict_almost_equal
dict_with_all_types_almost_equal
all_types_almost_equal

For each, we also have a corresponding ``assert_*`` function.

The only high-level functions which you really need are ``all_types_equal`` and
``all_types_almost_equal``. These also handle nested dicts with numpy arrays
etc. All other ``*equal()`` function are used by those for special cases, but
can also be called directly, of course.

How to change pre-defined comparison functions
----------------------------------------------
::

>>> import pwtools.test.tools as tt
>>> tt.all_types_almost_equal.comp_map[tt.arr_t] = \
... lambda x,y: np.allclose(x,y,atol=0.1,rtol=0.1)
>>> tt.assert_all_types_almost_equal.comp_func.comp_map[tt.arr_t] = \
... lambda x,y: np.allclose(x,y,atol=0.1,rtol=0.1)
"""

import warnings, copy, tempfile
import numpy as np
from pwtools import num
warnings.simplefilter('always')

# define types, could probably also use the types module
arr_t = type(np.array([1.0]))
dict_t = type({'1': 1})
float_t = type(1.0)
int_t = type(1)

def msg(txt):
    """Uncomment for debugging if tests fail."""
    print(txt)
##    pass

def err(txt):
    print('error: ' + txt)

def default_equal(a, b):
    return a == b

def array_equal(a,b):
    return (a==b).all()


def array_almost_equal(a, b, **kwds):
    return np.allclose(a, b, **kwds)


class AllTypesFactory(object):
    """Factory for creating functions which compare "any" type. We need a dict
    `comp_map` which maps types (result of ``type(foo)``) to a comparison
    function for that type which returns True or False and is called like
    ``comp_map[<type>](a,b)``. Also a ``comp_map['default']`` entry is needed.
    """
    def __init__(self, comp_map={}):
        """
        Parameters
        ----------
        comp_map : dict
            Dict with types and comparison fucntions.
            Example: ``{type(np.array([1.0])): np.allclose, 
                        type(1): lambda x,y: x==y,
                        'default': lambda x,y: x==y}``
        """
        self.comp_map = comp_map
    
    def __call__(self, d1, d2, strict=False):
        """
        Parameters
        ----------
        d1, d2 : any type
            Things to compare.
        strict : bool
            Force equal types. Then 1.0 and 1 are not equal.
        """
        d1_t = type(d1)
        d2_t = type(d2)
        if strict:
            if d1_t != d2_t: 
                err("AllTypesFactory: d1 (%s) and d2 (%s) are not the "
                      "same type" %(d1_t, d2_t))
                return False       
        for typ, comp_func in self.comp_map.iteritems():
            if d1_t == typ:
                msg("AllTypesFactory: type=%s, comp_func=%s" \
                      %(str(typ), str(comp_func)))
                return comp_func(d1, d2)
        if self.comp_map.has_key('default'):
            comp_func = self.comp_map['default']
        else:
            raise StandardError("no default comparison function defined, "
                "cannot process type=%s" %(d1_t))
        msg("AllTypesFactory: type=default, comp_func=%s" \
              %str(comp_func))
        return comp_func(d1, d2)          


class AssertFactory(object):
    """Factory for comparison functions which simply do ``assert
    comp_func(*args, **kwds)``."""
    def __init__(self, comp_func=None):
        self.comp_func = comp_func
    
    def __call__(self, *args, **kwds):
        assert self.comp_func(*args, **kwds)


# comp maps for AllTypesFactory, without dicts
comp_map_no_dict_equal = {\
    arr_t: array_equal,
    'default': default_equal,
    }

comp_map_no_dict_almost_equal = {\
    arr_t: array_almost_equal,
    int_t: array_almost_equal,
    float_t: array_almost_equal,
    'default': default_equal,
    }

# compare all types, but no dicts
all_types_no_dict_equal = AllTypesFactory(comp_map=comp_map_no_dict_equal)
all_types_no_dict_almost_equal = AllTypesFactory(comp_map=comp_map_no_dict_almost_equal)


class DictWithAllTypesFactory(object):
    """Factory for creating functions which can compare dicts with values of
    "any" type, also numpy arrays. Nested dicts are possible."""
    def __init__(self, comp_func=None):
        self.comp_func = comp_func
    
    def __call__(self, d1, d2, keys=None, strict=False, attr_lst=None):
        """
        Parameters
        ----------
        d1, d2 : dicts
        keys : sequence of dict keys, optional
            Compare only d1[key] and d2[key] for key in keys. Else compare all
            entries.
        strict : bool
            Force equal types in each dict value. Then 1.0 and 1 are not equal.
        """
        if attr_lst is not None:
            warnings.warn("'attr_lst' keyword deprecated. Use 'keys' instead.",
                          DeprecationWarning)
            keys = attr_lst
        # Test equal keys only if user doesn't provide them.            
        if keys is None:            
            d1_keys = d1.keys()    
            d2_keys = d2.keys()
            if len(d1_keys) != len(d2_keys):
                err("DictWithAllTypesFactory: key list not equally long")
                return False
            if set(d1_keys) != set(d2_keys):
                err("DictWithAllTypesFactory: keys not equal")
                return False
        _keys = d1_keys if keys is None else keys    
        ret = True
        for key in _keys:
            msg("DictWithAllTypesFactory: testing key=%s" %key)
            d1_t = type(d1[key])
            d2_t = type(d2[key])
            if strict:
                if d1_t != d2_t: 
                    err("DictWithAllTypesFactory: d1[%s] (%s) and d2[%s] (%s) are not "
                          "the same type" %(key, d1_t, key, d2_t))
                    return False
            if d1_t == dict_t:
                msg("  DictWithAllTypesFactory: case: dict, recursion")
                ret = ret and self(d1[key], d2[key])
            else:
                msg("  DictWithAllTypesFactory: case: something else, "
                      "comp_func=%s" %str(self.comp_func))
                ret = ret and self.comp_func(d1[key], d2[key])
        return ret


def assert_attrs_not_none(pp, attr_lst=None, none_attrs=[]):
    """Assert that ``pp.<attr>`` is not None for all attribute names (strings)
    in ``attr_lst``.

    Parameters
    ----------
    pp : something to run getattr() on, may have the attribute "attr_lst"
    attr_lst : sequence of strings, optional
        Attribute names to test. If None then we try ``pp.attr_lst`` if it
        exists.
    none_attrs : sequence of strings, optional
        attr names which are allowed to be None
    """
    if attr_lst is None:
        if hasattr(pp, 'attr_lst'):
            attr_lst = pp.attr_lst
        else:
            raise StandardError("no attr_lst from input or test object 'pp'")
    for name in attr_lst:
        msg("assert_attrs_not_none: testing: %s" %name)
        attr = getattr(pp, name)
        if name not in none_attrs:
            assert attr is not None, "FAILED: obj: %s attr: %s is None" \
                %(str(pp), name)

# compare dicts with any type as values, dict values cause recusion until a
# non-dict is found, that is the compared with comp_func
dict_with_all_types_equal = DictWithAllTypesFactory(all_types_no_dict_equal)
dict_with_all_types_almost_equal = DictWithAllTypesFactory(all_types_no_dict_almost_equal)

comp_map_equal = copy.deepcopy(comp_map_no_dict_equal)
comp_map_equal[dict_t] = dict_with_all_types_equal
comp_map_almost_equal = copy.deepcopy(comp_map_no_dict_almost_equal)
comp_map_almost_equal[dict_t] = dict_with_all_types_almost_equal

# compare all types, also dicts
all_types_equal = AllTypesFactory(comp_map_equal)
all_types_almost_equal = AllTypesFactory(comp_map_almost_equal)

# convenience shortcuts and backwd compat: assert_foo(a,b) = assert foo(a,b)
assert_dict_with_all_types_equal = AssertFactory(dict_with_all_types_equal)
assert_dict_with_all_types_almost_equal = AssertFactory(dict_with_all_types_almost_equal)
assert_all_types_equal = AssertFactory(all_types_equal)
assert_all_types_almost_equal = AssertFactory(all_types_almost_equal)
assert_array_equal = AssertFactory(array_equal)
assert_array_almost_equal = AssertFactory(array_almost_equal)

# backwd compat
adae = assert_dict_with_all_types_almost_equal
ade = assert_dict_with_all_types_equal
aaae = assert_array_almost_equal
aae = assert_array_equal


