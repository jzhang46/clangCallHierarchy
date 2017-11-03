#!/usr/bin/python
#  -*- coding: UTF-8 -*-


import sys
import os.path
import sqlite3
from functools import partial
from StringIO import StringIO
import re


#NOTE: Because this file was modified based on the caller.py, there are many function/variable names called caller, while in fact, in this context, it means callee

db_path  = "/Users/sogou/Tools/clangCallHierarchy/build/Debug/db.sqlite"

file_name_to_content = {}
g_cursor = None
keyword_to_oc_func = {'im':'-', 'cm':'+'} #, 'py':'-prop'}
oc_func_to_keyword = {'-':'im', '+':'cm'}
g_method_to_set = {}


def get_objc_string_from_res(resolution):
    m = re.match(r"(c:objc\(\w+\))(\w+)\((\w+)\)([\w:]+)", resolution)
    if m is not None:
        g = m.groups()
        if g[0] == 'c:objc(cs)':
            if g[2] in keyword_to_oc_func:
                prefix = keyword_to_oc_func[g[2]]
                return '%s[%s %s]' %(prefix, g[1], g[3])
    else:
        if resolution.startswith('c:@F@'):
            return resolution[5:]

    if resolution.startswith('c:objc(cs)'):
        resolution = resolution[10:]

    return resolution


def get_res_from_objc_method(method):
    m = re.match(r"([+-])\[(\w+) ([\w:]+)\]", method)
    g = m.groups()
    if g[0] in oc_func_to_keyword:
        keyword = oc_func_to_keyword[g[0]]
        return "c:objc(cs)%s(%s)%s" % (g[1], keyword, g[2])
    return method


def get_res_from_c_method(method):
    return "c:@F@%s" % method


def get_callees_for_resolution(method_res):
    callees = []

    #get position from resolution file for the resolution
    if len(method_res) == 0:
        print "error: didnot find %s" % resolution
        return []

    sql = "SELECT callee, callee_file, callee_row, callee_col FROM oc_references r " \
          "WHERE caller ==?"
    query = g_cursor.execute(sql, (str(method_res),))
    results = query.fetchall()
    for r in results:
        callees.append(r)
    sorted(callees)
    return callees


# Used for recording all {func, [direct children]} relations
g_parent_to_children = {}


def fetch_allmethods(parent_method_res, child_method_symbols):
    """Print all parent-child relations, in one level"""
    
    # method_res = method_symbol[0]
    if not parent_method_res or len(parent_method_res) == 0:
        return

    #Already handled the parent, no need to go down, otherwise would recurse to infinity
    if parent_method_res in g_parent_to_children:
        return;

    s = set()
    g_parent_to_children[parent_method_res] = s

    for method_symbol in child_method_symbols:
        s.add(method_symbol)
        method_res = method_symbol[0]
        callers = get_callees_for_resolution(method_res)
        if callers and len(callers) > 0:
            fetch_allmethods(method_res, callers)


def print_all_descendents(method_symbol):
        """ Print all descendents and its direct children """
        # method_res = method_symbol[0]
        fetch_allmethods("root", [method_symbol])
        for key in sorted(g_parent_to_children.iterkeys()):
            s = g_parent_to_children[key]
            if len(s) < 1 or key == "root":
                continue
            print "%s" % get_objc_string_from_res(key)
            for val in sorted(s):
                print "\t%s" % ';'.join(get_objc_string_from_res(str(elm)) for elm in val)


def main(method):
    global g_cursor
    global db_path

    # arg_count = len(sys.argv)
    # if arg_count > 1:
    #     db_path = sys.argv[1]
    #     if not db_path:
    #         print 'Could not find index folder for project: %s' % sys.argv[1]
    #         exit(0)
    #     if arg_count > 2:
    #         method = sys.argv[2]
    # else:
    #     print 'Format: python callee.py project_path [func_name]'
    #     exit(0)

    # if not os.path.exists(db_path):
    #     print 'Error: Cannot find database at: %s' % db_path
    #     return

    db = sqlite3.connect(db_path)
    g_cursor = db.cursor()

    if method.find('[') >= 0:
        method_name = get_res_from_objc_method(method)
    else:
        method_name = get_res_from_c_method(method)

    # Print the call hierarchy
    # print_callhierarchy("", "root", method_name)

    # Print the descendents impl
    print_all_descendents((method_name, "", 0, 0))

    g_cursor.close()
    db.close()
    g_cursor = None

if __name__ == "__main__":
    main('-[KeyboardViewController viewDidLoad]')
