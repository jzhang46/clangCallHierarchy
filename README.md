# clangCallHierarchy

This little tool can help find all the callees of the specified functions in a Xcode project.

It's composed of two parts:
* Index the files in the **project_path** using libclang, and store the calling information to a sqlitedb
* Find the functions called by user-specified-function list recursively and output to stdout

Usage:
```Bash
$python callees.py project_path task_label_name
```

Some technical details:
* In order to use libclang to do the indexing, I need the build option of each file in the project. But as is well known, there are a lot of settings configured in the project settings, and it's project specific. What I do here is: I first do a full build of the project/workspace, and save the build output to a temp file, and parse the output to crunch out build setting for each individual file - which means it may take a while if the project is large.
  * Because the target functions may be a list, I didn't make them as an argument or an input file, you may need to modify the __main__ function in the callees.py file directly.
  
  * Because different projects may have different xcodebuild parameters, I didn't extract those build commands into an argument or input file, you would need to modify the **buildProjectToGetOutputLog()** function in the callees.py file.
* The clangCallHierarchy is a standalone tool that do the real indexing. It's produced by the objc project in the **index** subfolder, which directly uses libclang. It's a standalone tool, supporting the following arguments:  
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
