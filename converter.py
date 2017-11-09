#!/usr/bin/python
#  -*- coding: UTF-8 -*-


import sys
import os.path
import sqlite3
from functools import partial
from StringIO import StringIO
import re
import os
import subprocess
import datetime

project_path = ""

keyword_to_oc_func = {'im':'-', 'cm':'+'} #, 'py':'-prop'}
oc_func_to_keyword = {'-':'im', '+':'cm'}

# Used for recording all {func, [direct children]} relations
g_parent_to_children = {}


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


def get_method_symbol_description(method_symbol):
    # convert the tuple to list
    method_symbol_list = list(method_symbol)
    # get the filepath from the list 
    file_path = method_symbol_list[1]
    # remove the dir prefix
    file_path = file_path[len(project_path):]
    # set it back to list
    method_symbol_list[1] = file_path
    # combine them with ';'
    method_symbol_desc = ';'.join(get_objc_string_from_res(str(element)) for element in method_symbol_list)
    return method_symbol_desc


def get_callees_for_resolution(g_cursor, method_res):
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


# recursive method
def fetch_allmethods(g_cursor, parent_method_res, child_method_symbols):
    """Print all parent-child relations, in one level"""
    
    global g_parent_to_children

    # parent_method_res should be valid
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
        callees = get_callees_for_resolution(g_cursor, method_res)
        if callees and len(callees) > 0:
            fetch_allmethods(g_cursor, method_res, callees)


# method_symbol format: (method_resolution, file_path, row_num, col_num)
def print_all_descendents(g_cursor, method_symbol):
    """ Print all descendents and its direct children """
    global g_parent_to_children

    # method_res = method_symbol[0]
    fetch_allmethods(g_cursor, "root", [method_symbol])
    for key in sorted(g_parent_to_children.iterkeys()):
        s = g_parent_to_children[key]
        if len(s) < 1 or key == "root":
            continue
        print "%s" % get_objc_string_from_res(key)
        for child_symbol in sorted(s):
            method_symbol_desc = get_method_symbol_description(child_symbol)
            print "\t%s" % method_symbol_desc


def find_call_hierarchy(db_path, method):

    db = sqlite3.connect(db_path)
    g_cursor = db.cursor()

    if method.find('[') >= 0:
        method_name = get_res_from_objc_method(method)
    else:
        method_name = get_res_from_c_method(method)

    # Print the call hierarchy
    # print_callhierarchy("", "root", method_name)

    # Print the descendents impl
    method_symbol = (method_name, "", 0, 0)
    print_all_descendents(g_cursor, method_symbol)

    g_cursor.close()
    db.close()
    g_cursor = None


#The build process may be different for each project
def buildProjectToGetOutputLog(workSpacePath):
    xcrun_cmd = '/usr/bin/xcrun'
    clang_path = subprocess.check_output([xcrun_cmd, '--find', 'clang']).strip()
    
    # Run the build
    print 'Building the workspace...'
    basename = "/tmp/build_output_log"
    suffix = datetime.datetime.now().strftime("%y%m%d_%H%M%S")
    output_log_path = "_".join([basename, suffix])
    build_cmd = '%s xcodebuild build -workspace %s/SogouInput.xcworkspace -scheme BaseKeyboard -sdk iphonesimulator11.1 -arch x86_64 -configuration Release > %s' % (xcrun_cmd, workSpacePath, output_log_path)
    os.system(build_cmd)
    return output_log_path


def getBuidArgsFor(workSpacePath):
    output_log_path = buildProjectToGetOutputLog(workSpacePath)
    # output_log_path = '/tmp/build_output_log_171103_211338'

    # Read the log file
    print 'Parsing build output...'
    build_output_file = open(output_log_path)
    build_output = build_output_file.read()
    build_output_file.close();
    build_out_list = build_output.split('\n')

    # Parse the log file contents
    fileName2BuildArgs = {} #Dictionary of <fileName, list of arguments>
    for line in build_out_list:
        line = line.strip()
        if line.startswith(clang_path):
            line_components = line.split(' ')
            if '-c' not in line_components:
                continue
            prev_index = line_components.index('-c')
            if prev_index > 0:
                file_name = line_components[prev_index+1]
                del line_components[prev_index:] # remove -c and -o args
                del line_components[:1]         #remove the clang path
                i = 0
                for component in line_components:
                    if component.endswith('BaseKeyboard.pch'):
                        line_components[i] = '%s/BaseKeyboard/BaseKeyboard.pch' % workSpacePath
                    elif component.endswith('SogouInput.pch'):
                        line_components[i] = '%s/SogouInput/SogouInput.pch' % workSpacePath
                    i = i+1

                fileName2BuildArgs[file_name] = ' '.join(line_components)

    os.remove(output_log_path)
    print 'Parsing completed.'

    return fileName2BuildArgs


def createReferenceDB(project_path, out_db_path, arg_path):
    # Build the project
    print 'Crunching out the build arguments...'
    fileName2BuildArgs = getBuidArgsFor(project_path)
    
    # Write the build options to the arg_path
    argFile = open(arg_path, 'w+')
    for fileName in fileName2BuildArgs:
        argFile.write(fileName + '\n')
        argFile.write(fileName2BuildArgs[fileName] + '\n')
    argFile.close()

    # Do the indexing
    print 'Indexing...'
    cmd = './clangCallHierarchy -o %s -a %s %s' % (db_path, arg_path, project_path)
    os.system(cmd)


def mainFunc(project_path, db_path, arg_path, methods, needRebuild = True):
    global g_parent_to_children

    if needRebuild:
        createReferenceDB(project_path, db_path, arg_path)

    # Find call hierarchy from DB
    for method in methods:
        print '\n========== %s ==========\n' % method
        g_parent_to_children.clear()
        find_call_hierarchy(db_path, method)


if __name__ == "__main__":
    # Relevant methods
    methods = {'-[KeyboardViewController initWithNibName:bundle:]',
               '-[KeyboardViewController viewDidLoad]',
               '-[SGIKeyView layoutSubviews]',
               '-[SGIMainView layoutSubviews]',
               '-[SGIKeyboard layoutSubviews]',
               '-[SGIInputSupplementaryView layoutSubviews]',
               '-[SGIInputSupplementaryCellTableViewCell drawRect:]'}

    # Create the output data folder if not exists
    output_folder = "./out_data"
    if not os.path.exists(output_folder):
        os.makedirs(output_folder)

    arg_count = len(sys.argv)
    if arg_count > 2:
        project_path = sys.argv[1]
        label = sys.argv[2]
        if len(label) == 0:
            print 'Invalid label.'
            exit(0)
        db_path = '%s/%s_db.sqlite' % (output_folder, label)
        arg_path = '%s/%s_buildArguments.txt' % (output_folder, label)
    else:
        print 'usage: python converter.py project_path task_label_name'
        exit(0)

    if not os.path.exists(project_path):
        print 'Could not find target folder for project: %s' % project_path
        exit(0)

    mainFunc(project_path, db_path, arg_path, methods, False)
