//
//  main.m
//  clangCallHierarchy
//
//  Created by sogou on 27/10/2017.
//  Copyright © 2017 sogou. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <clang-c/Index.h>
#include <stdlib.h>
#include <unistd.h>
#include <ftw.h>
#include <time.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#import <sqlite3.h>


static const char *SQL_DROP_TABLE = "DROP TABLE IF EXISTS oc_references;";
static const char *SQL_CREATE_TABLE = "CREATE TABLE IF NOT EXISTS oc_references (caller TEXT, caller_file TEXT, caller_row INT, caller_col INT, callee TEXT, callee_file TEXT, callee_row INT, callee_col INT);";
static const char *SQL_INSERT_STATEMENT = "INSERT INTO oc_references VALUES('%s', '%s', %d, %d, '%s', '%s', %d, %d);";


sqlite3 *sqlite3DataBase = NULL;

void closeDB() {
    sqlite3_close(sqlite3DataBase);
}

void runQuery(char *query) {
    sqlite3_stmt *compiledStatement;
    int prepareResult = sqlite3_prepare_v2(sqlite3DataBase, query, -1, &compiledStatement, NULL);
    if(prepareResult != SQLITE_OK) {
        fprintf(stderr, "DB error: %s", sqlite3_errmsg(sqlite3DataBase));
        closeDB();
        assert(false);
    }
    
    BOOL execResult = sqlite3_step(compiledStatement);
    if (execResult != SQLITE_DONE) {
        fprintf(stderr, "DB error: %s", sqlite3_errmsg(sqlite3DataBase));
        return;
    }
    sqlite3_finalize(compiledStatement);
}

void openOrCreateDB(const char *db_path) {
    const char *filePath = db_path;
    
    int openDataBaseResult = sqlite3_open(filePath, &sqlite3DataBase);
    assert(openDataBaseResult == SQLITE_OK);
    char *sql = (char *)SQL_DROP_TABLE;
    runQuery(sql);
    sql = (char *)SQL_CREATE_TABLE;
    runQuery(sql);
}

typedef struct SymbolPosition {
    char *symbol;
    char *file;
    int row;
    int col;
} SymbolPosition;

char *createInsertQueryFor(SymbolPosition caller, SymbolPosition callee) {
    char *statement = (char *)malloc(1000);
    memset(statement, 0, 1000);
    
    sprintf(statement, SQL_INSERT_STATEMENT, caller.symbol, caller.file, caller.row, caller.col, callee.symbol, callee.file, callee.row, callee.col);
    return statement;
}

void destroyInsertQuery(char *statement) {
    free(statement);
}

CXIndex g_clangIndex;
NSArray *g_args;

static void freestring(CXString *str)
{
    clang_disposeString(*str);
}

#define SCOPED_STR(name, value)\
__attribute__((unused))\
__attribute__((cleanup(freestring))) CXString name ## str = value;\
const char *name = clang_getCString(name ## str);

#define NS_STR(name, value) \
SCOPED_STR(name, value) \
NSString *str_##name = [NSString stringWithUTF8String: name];

static enum CXChildVisitResult
visitor(CXCursor cursor, CXCursor parent, CXClientData client_data);

static enum CXChildVisitResult
methodImplVisitor (CXCursor cursor, CXCursor parent, CXClientData client_data);

static enum CXChildVisitResult
functionCallVisitor(CXCursor cursor, CXCursor parent, CXClientData client_data) {
    enum CXCursorKind kind = clang_getCursorKind(cursor);
    if (clang_isInvalid(kind))
        return CXChildVisit_Recurse;

    if (kind != CXCursor_ObjCMessageExpr && kind != CXCursor_CallExpr)
        return CXChildVisit_Recurse;
    
    CXCursor referenced = clang_getCursorReferenced(cursor);
    if (!clang_isInvalid(referenced.kind)) {
        SCOPED_STR(usr, clang_getCursorUSR(referenced));
        CXSourceLocation loc = clang_getCursorLocation(cursor);
        CXFile file;
        unsigned row, col, offset;
        clang_getExpansionLocation(loc, &file, &row, &col, &offset);
        SCOPED_STR(fileName, clang_getFileName(file));
        SymbolPosition callee = {.file = (char *)fileName, .row = row, .col = col};
        callee.symbol = (char *)usr;
        
        SymbolPosition caller = *(SymbolPosition *)client_data;
        
        char *statement = createInsertQueryFor(caller, callee);
        runQuery(statement);
        destroyInsertQuery(statement);
    }
    return CXChildVisit_Recurse;
}

static enum CXChildVisitResult methodImplVisitor (CXCursor cursor, CXCursor parent, CXClientData client_data) {
    enum CXCursorKind kind = clang_getCursorKind(cursor);
    if (kind != CXCursor_ObjCInstanceMethodDecl && kind != CXCursor_ObjCClassMethodDecl && kind != CXCursor_ObjCPropertyDecl)
        return CXChildVisit_Recurse;
    
    SCOPED_STR(implUSR, clang_getCursorUSR(cursor));
    
    CXSourceLocation loc = clang_getCursorLocation(cursor);
    CXFile file;
    unsigned row, col, offset;
    clang_getExpansionLocation(loc, &file, &row, &col, &offset);
    SCOPED_STR(fileName, clang_getFileName(file));
    SymbolPosition p = {.file = (char *)fileName, .row = row, .col = col};
    p.symbol = (char *)implUSR;
    
    int nextLevel = nextLevel;
    clang_visitChildren(cursor, functionCallVisitor, &p);
    return CXChildVisit_Continue;
}

static enum CXChildVisitResult
visitor(CXCursor cursor, CXCursor parent, CXClientData client_data) {
    enum CXCursorKind kind = clang_getCursorKind(cursor);
    if (kind != CXCursor_ObjCImplementationDecl && kind != CXCursor_ObjCCategoryImplDecl)
        return CXChildVisit_Continue;

    clang_visitChildren(cursor, methodImplVisitor, client_data);
    return CXChildVisit_Recurse;
}

NSMutableDictionary *g_FileName2BuildArgs;

void handleFile(const char* mainFile) {
    NSString *filePath = [NSString stringWithUTF8String:mainFile];
    NSString *args = [g_FileName2BuildArgs objectForKey:filePath];
    if (!args) {
        return;
    }
    
    NSArray *argList = [args componentsSeparatedByString:@" "];
    
    int argc = (int)[argList count];
    const char *argv[argc];
    int i=0;
    for (NSString *arg in argList) {
        argv[i++] = [arg UTF8String];
    }
    
    CXTranslationUnit translationUnit;
    enum CXErrorCode errorCode =clang_parseTranslationUnit2FullArgv(g_clangIndex,
                                                                    mainFile, argv, argc, 0,
                                                                    0,
                                                                    CXTranslationUnit_Incomplete |
                                                                    CXTranslationUnit_DetailedPreprocessingRecord |
                                                                    CXTranslationUnit_ForSerialization, &translationUnit);
    if (errorCode == CXError_Success) {
        unsigned int treeLevel = 0;
        clang_visitChildren(clang_getTranslationUnitCursor(translationUnit), visitor, &treeLevel);
    }
    clang_disposeTranslationUnit(translationUnit);
}



int handle_entry(const char *filepath, const struct stat *info,
                const int typeflag, struct FTW *pathinfo)
{
    if (typeflag == FTW_F) {
        if (strstr(filepath, ".m") || strstr(filepath, ".mm") || strstr(filepath, ".cpp")) {
            printf("Processing %s\n", filepath);
            handleFile(filepath);
        }
    }
    return 0;
}


int handle_directory_tree(const char *const dirpath)
{
    int result;
    
    /* Invalid directory path? */
    if (dirpath == NULL || *dirpath == '\0')
        return errno = EINVAL;
    
    result = nftw(dirpath, handle_entry, 20, FTW_PHYS);
    if (result >= 0)
        errno = result;
    
    return errno;
}

void doWork(const char *working_dir, const char *buildOptionFilePath) {
    g_clangIndex = clang_createIndex(0, 1);

    g_FileName2BuildArgs = [NSMutableDictionary dictionary];
    
    NSString *plistPath = [NSString stringWithUTF8String:buildOptionFilePath];
    NSError *file_error = nil;
    NSString *fileContents = [NSString stringWithContentsOfFile:plistPath encoding:NSUTF8StringEncoding error:&file_error];
    assert(file_error == nil);
    
    NSArray *lines = [fileContents componentsSeparatedByString:@"\n"];
    NSUInteger lineCount = lines.count;
    if (lineCount % 2 != 0) {
        lineCount -= 1;
    }
    
    for (int i = 0; i <= lineCount-1; i+=2) {
        NSString *fileName = lines[i];
        NSString *args = lines[i+1];
        if (!fileName.length || !args.length) {
            continue;
        }
        [g_FileName2BuildArgs setObject:args forKey:fileName];
    }
    
//    NSData *plistData = [NSData dataWithContentsOfFile:plistPath];
//
//    // Load the options required to compile GNUstep apps
//    NSError *error = nil;
//    g_args = [NSPropertyListSerialization propertyListWithData:plistData
//                                                              options:NSPropertyListImmutable
//                                                               format:nil
//                                                                error:&error];
//    assert(error == nil);//@"defaultArgument.plist read error!"
    
    handle_directory_tree(working_dir);
//    handle_directory_tree("/Users/sogou/bsl/SogouInput/SogouInput_4.9.0_mergeCore/BaseKeyboard");
//    handleFile("/Users/sogou/bsl/SogouInput/SogouInput_4.9.0_new/BaseKeyboard/Controller/KeyboardViewController.m");
//    handleFile("./test_data/a.m");
//    handleFile("/Users/sogou/bsl/SogouInput/SogouInput_4.9.0_new/BaseKeyboard/Controller/SGIKeyboard.m");
}

int main(int argc, const char * argv[]) {
    extern char *optarg;
    extern int optind, optopt;
    int c;
    const char *build_option_path = "./BuildArguments.txt";
    const char *output_db_path = "./output_db.sqlite";
    int errflg = 0;
    
    
    while((c = getopt(argc, (char * const *)argv, "a:o:")) != -1) {
        switch (c) {
            case 'a':
                build_option_path = optarg;
                break;
            case 'o':
                output_db_path = optarg;
                break;
            case ':':
                fprintf(stderr, "Option -%c requires an operand\n", optopt);
                errflg++;
                break;
            case '?':
                fprintf(stderr, "Unrecognized option: -%c\n", optopt);
                errflg++;
            default:
                break;
        }
    }
    
    if (errflg || optind >= argc) {
        fprintf(stderr, "usage: clangCallHierarchy working_directory_path -o out_db_path -a build_option_path");
        return -1;
    }
    
    const char *dir_path = argv[optind];
    
    openOrCreateDB(output_db_path);
    doWork(dir_path, build_option_path);
    closeDB();
    
    return 0;
}
