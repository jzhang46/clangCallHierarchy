# clangCallHierarchy

This little tool can help find all the calltree of the specified functions in a Xcode project.

It's composed of two parts:
* Index the files in the **project_path** using libclang, and store the calling information to a sqlitedb
* Find the functions called-by/calling user-specified-function list recursively and output to stdout

Usage:
```Bash
$python calltree.py -w project_path -c build_cmd_file_path -n task_label_name
```
 * *project_path* need to be a **full(absolute) path** 
 * *build_cmd_file_path* is a file that contains command lines to build the project
 * *task_label_name* is used to name the temporary files and the resultant sqlite db, which can be found in the ./out_data folder

```Bash
$python calltree.py -h
usage: calltree.py [-h] -w PROJECT_PATH -n LABEL_NAME [-c BUILDCOMMAND_FILE]
                   [-f INPUT_FILE] [--caller] [--callee] [-s]

A tool to extract call hierarchy information for target functions in a clang
project.

required arguments:
  -w PROJECT_PATH, --workspace PROJECT_PATH
                        a workspace dir path contaning the source code.
  -n LABEL_NAME, --name LABEL_NAME
                        a name used to name the resultant files int the
                        out_data folder.
  -c BUILDCOMMAND_FILE, --command BUILDCOMMAND_FILE
                        a file path contaning the commandline for building the
                        project, default uses ./project_build_cmd.txt.

optional arguments:
  -h, --help            show this help message and exit
  -f INPUT_FILE, --inputfile INPUT_FILE
                        an txt file containing target functions, default uses
                        ./input.txt.
  --caller              find callers of the target functions, default is
                        false.
  --callee              find callees of the target functions, default is true.
  -s, --skipIndex       skip the indexing part, default is not skipping.
``` 
Example:
```Bash
python calltree.py -w `pwd`/example/DemoProject -c ./project_build_cmd.txt -n Demo1
```

Some technical details:
* In order to use libclang to do the indexing, I need the full clang options of each file in the project. But as is well known, there are a lot of settings configured in the project settings, and it's project (or maybe file) specific. What I do here is: first do a full build of the project/workspace (maybe a dry-run with -n is ok too, if the artifacts it depends on are available), and save the build output to a temp file, and then parse the output to carve out build setting for each file - which means it may take a while if the project is large.
  * The target functions may be a list, you should fill them into a txt file and specify the file as -f argument.
  
  * Different projects may have different xcodebuild parameters, you should put the full command line to a txt file and specify it as the -c argument.

  * There were some problem with the precompiled pch(binary) when I feed the build args to libclang, didn't find the root cause though. As a workaround, I replaced the .pch in the args to point to the .pch(text) in the source folder, which means you may need to customize the **substitutePCHInLineComponents()** function to handle your own pch replacement...
    > Please send me a note if you have made the default pch to work with libclang... I'd be happy to hear from you.

* The clangCallHierarchy is a **standalone** tool that does the heavy lifting under the hood. It's the one that does the real indexing. It's produced by the objc project in the **index** subfolder, which directly uses libclang. It's a standalone executable, supporting the following arguments:  
  ```Bash
  $./clangCallHierarchy [-o output_db_file_path] -a build_argument_file_path project_path
  ```
    * Please be noted that build_argument_file_path points to a file that contains build arguments for each file in the project_path. It's format is as follows (file and its corresponding args in consecutive lines):
        ```Bash
        file_path_1
        build_arguments_string_1
        file_path_2
        build_arguments_string_2
        ```
