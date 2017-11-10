# clangCallHierarchy

This little tool can help find all the callees of the specified functions in a Xcode project.

It's composed of two parts:
* Index the files in the **project_path** using libClang, and store the calling information to a sqlitedb
* Find the functions called by user-specified-function list recursively and output to stdout

Usage:
```Bash

$python callees.py project_path task_label_name

```
