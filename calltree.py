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
import argparse



# NOTE: 
def substitutePCHInLineComponents(workSpacePath, line_components):
    """The following substutes the .pch in the build folder with the .pch in the workspace, 
    because there's some problem with the pch in the build folder, don't know why :(
    The input param (line_components) is a list of commandline arguments consumed by clang
    Again, you may or may not need to do this.."""
    i = 0
    for component in line_components:
        if component.endswith('BaseKeyboard.pch'):
            line_components[i] = '%s/BaseKeyboard/BaseKeyboard.pch' % workSpacePath
        elif component.endswith('MyProject.pch'):
            line_components[i] = '%s/MyProject/MyProject.pch' % workSpacePath
        i = i+1
    return line_components


############################ Implementation ################################

project_path = ""

keyword_to_oc_func = {'im':'-', 'cm':'+'} #, 'py':'-prop'}
oc_func_to_keyword = {'-':'im', '+':'cm'}

# Used for recording all {func, [direct children]} relations
g_parent_to_children = {}


def get_objc_string_from_res(resolution):
    """Convert the objc usr to normal format"""

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


def get_callers_for_resolution(g_cursor, method_res):
    callers = []
    if len(method_res) == 0:
        print "error: didnot find %s" % resolution
        return []
    sql = "select id from oc_impls where function==?"
    query = g_cursor.execute(sql, (str(method_res),))
    results = query.fetchall()
    if len(results) == 0:
        return []
    callee_id, = results[0]

    sql = "select i.function, i.definition_file, i.definition_row, r.callsite_offset from oc_references as r join oc_impls as i on r.caller_id==i.id where r.callee_id==?;"
    query = g_cursor.execute(sql, (str(callee_id),))
    results = query.fetchall()
    for r in results:
        caller, caller_definition_file, caller_definition_row, reference_offset = r;
        callers.append((caller, caller_definition_file, caller_definition_row + reference_offset))
    sorted(callers)
    return callers


def get_callees_for_resolution(g_cursor, method_res):
    callees = []

    #get position from resolution file for the resolution
    if len(method_res) == 0:
        print "error: didnot find %s" % resolution
        return []

    sql = "select id, definition_file, definition_row as tid from oc_impls where function==?"
    query = g_cursor.execute(sql, (str(method_res),))
    results = query.fetchall()
    if len(results) == 0:
        return []
    caller_id, definition_file, definition_row = results[0]

    sql = "select i.function, r.callsite_offset from oc_references as r join oc_impls as i on r.callee_id==i.id where r.caller_id==?;"
    query = g_cursor.execute(sql, (str(caller_id),))
    results = query.fetchall()
    for r in results:
        callee, offset = r;
        callees.append((callee, definition_file, definition_row+offset))
    sorted(callees)
    return callees


# recursive method
def fetch_allmethods(g_cursor, parent_method_res, child_method_symbols, findCallee = True):
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
        child_nodes = None
        if findCallee:
            child_nodes = get_callees_for_resolution(g_cursor, method_res)
        else:
            child_nodes = get_callers_for_resolution(g_cursor, method_res)
        if child_nodes and len(child_nodes) > 0:
            fetch_allmethods(g_cursor, method_res, child_nodes, findCallee)


# method_symbol format: (method_resolution, file_path, row_num, col_num)
def print_all_descendents(g_cursor, method_symbol, findCallee = True):
    """ Print all descendents and its direct children """
    global g_parent_to_children

    # method_res = method_symbol[0]
    fetch_allmethods(g_cursor, "root", [method_symbol], findCallee)
    for key in sorted(g_parent_to_children.iterkeys()):
        s = g_parent_to_children[key]
        if len(s) < 1 or key == "root":
            continue
        caller_func = get_objc_string_from_res(key)
        for child_symbol in sorted(s):
            method_symbol_desc = get_method_symbol_description(child_symbol)
            print "%s;%s" % (caller_func, method_symbol_desc)


def find_call_hierarchy(db_path, method, findCallee=True):
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
    print_all_descendents(g_cursor, method_symbol, findCallee)

    g_cursor.close()
    db.close()
    g_cursor = None


# # This function is for debug purpose, save the build output to a tmp file
# def saveDataToTmpFile(result):
#     script_name = os.path.splitext(__file__)[0]
#     basename = "/tmp/%s_build_log" % script_name
#     suffix = datetime.datetime.now().strftime("%y%m%d_%H%M%S")
#     output_log_path = "_".join([basename, suffix])
#     print 'output saved to: %s\n' % output_log_path
#     f = open(output_log_path, 'w+')
#     f.write(result)
#     f.close()


# def getBuildProjectCommand(workSpacePath):
#     """The command line to build the project."""
#     return 'xcodebuild -project DemoProject.xcodeproj -scheme DemoProject clean build'
#     #return 'xcodebuild -n -workspace MyProject.xcworkspace -scheme MyProject' # xcodebuild -n is a dry-run, that output the build args without actually building the project
#     #return 'make clean; make;' # Or use make


# Run the build
def buildProjectToGetOutputLog(workSpacePath, commandline):
    # Save the current working dir
    cwd = os.getcwd()
    os.chdir(workSpacePath)
    
    # Start building
    print 'Building the workspace...'

    # Get the build command for the project
    #build_cmd = getBuildProjectCommand(workSpacePath)
    build_cmd = commandline
    result = subprocess.check_output([build_cmd], shell=True, stderr=subprocess.STDOUT)

    # # For Debug: save the build output file to a tmp file
    # saveDataToTmpFile(result)

    # Restore the cwd
    os.chdir(cwd)
    return result


def getBuidArgsFor(workSpacePath, commandline):
    # Get building commandline args from build result
    build_output = buildProjectToGetOutputLog(workSpacePath, commandline)

    # # For Debug: Read from a tmp file
    # output_log_path = "/tmp/callees_build_log_171115_180549"
    # build_output_file = open(output_log_path)
    # build_output = build_output_file.read()
    # build_output_file.close();

    print 'Parsing build output...'

    build_out_list = build_output.split('\n')
    clang_path = subprocess.check_output(['/usr/bin/xcrun', '--find', 'clang']).strip()

    # Parse the log file contents
    fileName2BuildArgs = {} #Dictionary of <fileName, list of arguments>

    for line in build_out_list:
        line = line.strip()
        # Parse the lines starts with a xxx/bin/clang
        if line.startswith(clang_path):
            line_components = line.split(' ')
            # -c indicates that this is a compiling command
            if '-c' not in line_components:
                continue
            prev_index = line_components.index('-c')
            if prev_index > 0:
                # prev_index+1 is the index where the filePath is  located
                file_name = line_components[prev_index+1]
                # remove the -c & its latter parts
                del line_components[prev_index:] # remove -c and -o args
                # remove the xxx/bin/clang part
                del line_components[:1]         #remove the clang path
                
                line_components = substitutePCHInLineComponents(workSpacePath, line_components)

                fileName2BuildArgs[file_name] = ' '.join(line_components)
    if (len(fileName2BuildArgs) == 0):
        print 'Parsing failed?'
        return None
    print 'Parsing completed.'

    return fileName2BuildArgs


def createReferenceDB(project_path, commandline, out_db_path, arg_path):
    # Build the project
    print 'Carving out the build arguments...'
    fileName2BuildArgs = getBuidArgsFor(project_path, commandline)

    # Write the build options to the arg_path
    argFile = open(arg_path, 'w+')
    for fileName in fileName2BuildArgs:
        argFile.write(fileName + '\n')
        argFile.write(fileName2BuildArgs[fileName] + '\n')
    argFile.close()

    # Do the indexing
    print 'Indexing...'
    cmd = './clangCallHierarchy -o %s -a %s %s' % (out_db_path, arg_path, project_path)
    os.system(cmd)


def createIndexAndParse(project_path, db_path, arg_path, methods, findCallee, needRebuild, commandline):
    global g_parent_to_children

    # This function does the following things:
    # 1. Build the project to get build arguments
    # 2. Use libclang to index the individual files and save th caller-callee info in db
    if needRebuild:
        createReferenceDB(project_path, commandline, db_path, arg_path)

    # Find call hierarchy from DB
    for method in methods:
        method = method.strip()
        if len(method) == 0:
            continue
        print '\n========== %s ==========' % method
        g_parent_to_children.clear()
        find_call_hierarchy(db_path, method, findCallee)


def getEntranceFunctionsFor(input_file):
    f = open(input_file, 'r')
    contents = f.read()
    f.close()
    return contents.splitlines()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="A tool to extract call hierarchy information for target functions in a clang project.")
    optional = parser._action_groups.pop()
    required = parser.add_argument_group('required arguments')
    # required args
    required.add_argument('-w', '--workspace', action='store', default='', required=True, dest='project_path', help='a workspace dir path contaning the source code.')
    required.add_argument('-n', '--name', action='store', default='', required=True, dest='label_name', help='a name used to name the resultant files int the out_data folder.')
    # optional args
    optional.add_argument('-c', '--command', action='store', default='./project_build_cmd.txt', dest='buildcommand_file', help='a file path contaning the commandline for building the project, default uses ./project_build_cmd.txt.')
    optional.add_argument('-f', '--inputfile', action='store', default='./input.txt', dest='input_file', help='an txt file containing target functions, default uses ./input.txt.')
    optional.add_argument('--caller', action='store_false', default=True, dest='findCallee', help='find callers of the target functions, default is false.')
    optional.add_argument('--callee', action='store_true', default=True, dest='findCallee', help='find callees of the target functions, default is true.')
    optional.add_argument('-s', '--skipIndex', action='store_true', default=False, dest='skipIndex', help='skip the indexing part, default is not skipping.')
    # Parse the args
    parser._action_groups.append(optional)
    result = parser.parse_args()

    project_path = result.project_path
    command_file = result.buildcommand_file
    label_name = result.label_name
    input_file = result.input_file
    findCallee = result.findCallee
    needRebuild = not result.skipIndex

    # command line file
    if not os.path.exists(command_file):
        print 'File %s not found' % command_file
        exit(0)

    cf = open(command_file, 'r')
    commandline = cf.read()
    cf.close()
    commandline = commandline.strip()
    if len(commandline) == 0:
        print 'Empty build command file.'
        exit(0)

    # target functions file
    if not os.path.exists(input_file):
        print 'File %s not found' % input_file
        exit(0)
    methods = getEntranceFunctionsFor(input_file)
    if len(methods) == 0:
        print 'File %s is empty' % input_file
        exit(0)

    if len(label_name) == 0:
        print 'Please spepcify a valid label name'
        exit(0)

    # project path
    if not os.path.exists(project_path):
        print 'Could not find target folder for project: %s' % project_path
        exit(0)

    # Create the output data folder if not exists
    output_folder = "./out_data"
    if not os.path.exists(output_folder):
        os.makedirs(output_folder)

    db_path = '%s/%s_db.sqlite' % (output_folder, label_name)
    arg_path = '%s/%s_buildArguments.txt' % (output_folder, label_name)

    createIndexAndParse(project_path, db_path, arg_path, methods, findCallee, needRebuild, commandline)
