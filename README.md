# clangCallHierarchy

This little tool can help find all the callees of the specified functions in a Xcode project.

It's composed of two parts:
* Index the files in the **project_path** using libclang, and store the calling information to a sqlitedb
* Find the functions called by user-specified-function list recursively and output to stdout

Usage:
```Bash
$python callees.py project_path task_label_name
```
 * *project_path* need to be a **full(absolute) path** 
 * *task_label_name* is used to name the temporary files and the resultant sqlite db, which can be found in the ./out_data folder

Example:
```Bash
$python callees.py /Users/aaa/workarea/MyProject MyProject1
```

Some technical details:
* In order to use libclang to do the indexing, I need the full clang options of each file in the project. But as is well known, there are a lot of settings configured in the project settings, and it's project (or maybe file) specific. What I do here is: first do a full build of the project/workspace (maybe a dry-run with -n is ok too, if the artifacts it depends on are available), and save the build output to a temp file, and then parse the output to carve out build setting for each file - which means it may take a while if the project is large.
  * The target functions may be a list, but I didn't bother to make them as an argument or an input file, you may need to modify the **getEntranceFunctions()** function in the callees.py file directly.
  
  * Different projects may have different xcodebuild parameters, but I didn't extract those build commands into an argument or input file, you would need to modify the **getBuildProjectCommand()** function in the callees.py file.

  * There were some problem with the precompiled pch(binary) when I feed the build args to libclang, didn't find the root cause though. I did a trick to replace the .pch in the args to point to my own .pch(text) in the source folder, which means you may want to customize the **substitutePCHInLineComponents()** function to handle your own pch replacement...
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
