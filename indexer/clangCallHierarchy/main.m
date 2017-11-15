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

//Macros to make dealing with the libClang strings easy
#define SCOPED_STR(name, value)\
            __attribute__((unused))\
            __attribute__((cleanup(freestring))) CXString name ## str = value;\
            const char *name = clang_getCString(name ## str);

#define NS_STR(name, value) \
            SCOPED_STR(name, value) \
            NSString *str_##name = [NSString stringWithUTF8String: name];

//Symbol and its position
typedef struct SymbolPosition {
    char *symbol;
    char *file;
    int row;
    int col;
} SymbolPosition;

//SQL statements to operate on reference DB
static const char *SQL_DROP_REFERENCES_TABLE = "DROP TABLE IF EXISTS oc_references;";
static const char *SQL_CREATE_REFERENCES_TABLE = "CREATE TABLE IF NOT EXISTS oc_references (caller_id INT, callee_id INT, callsite_offset INT);";
static const char *SQL_INSERT_REFERENCE_STATEMENT = "INSERT INTO oc_references VALUES(%d, %d, %d);";

//SQL statements to operate on implementation DB
static const char *SQL_DROP_IMPLS_TABLE = "DROP TABLE IF EXISTS oc_impls;";
static const char *SQL_CREATE_IMPLS_TABLE = "CREATE TABLE IF NOT EXISTS oc_impls (id INTEGER PRIMARY KEY, function TEXT, definition_file TEXT, definition_row INT, definition_col INT);";
static const char *SQL_INSERT_IMPLS_STATEMENT = "INSERT INTO oc_impls VALUES(NULL, '%s', '%s', %d, %d);";

#pragma mark - Global variables

sqlite3 *g_sqlite3DataBase = NULL;
CXIndex g_clangIndex;
NSArray *g_args;
NSMutableDictionary *g_FileName2BuildArgs;

#pragma mark - DB related methods

void closeDB() {
    sqlite3_close(g_sqlite3DataBase);
}

typedef void(^HandleQueryResult)(sqlite3_stmt *);

void runQueryWithHandler(char *query, HandleQueryResult handler) {
    sqlite3_stmt *compiledStatement;
    int prepareResult = sqlite3_prepare_v2(g_sqlite3DataBase, query, -1, &compiledStatement, NULL);
    if(prepareResult != SQLITE_OK) {
        fprintf(stderr, "DB error: %s", sqlite3_errmsg(g_sqlite3DataBase));
        closeDB();
        assert(false);
    }
    
    BOOL execResult = sqlite3_step(compiledStatement);
    if (execResult != SQLITE_DONE && execResult != SQLITE_ROW) {
        fprintf(stderr, "DB error: %s", sqlite3_errmsg(g_sqlite3DataBase));
        return;
    }
    
    if (handler) {
        handler(compiledStatement);
    }
    
    sqlite3_finalize(compiledStatement);
}

void runQuery(char *query) {
    runQueryWithHandler(query, nil);
}

void openOrCreateDB(const char *db_path) {
    const char *filePath = db_path;
    int openDataBaseResult = sqlite3_open(filePath, &g_sqlite3DataBase);
    assert(openDataBaseResult == SQLITE_OK);
    char *sql = (char *)SQL_DROP_REFERENCES_TABLE;
    runQuery(sql);
    sql = (char *)SQL_CREATE_REFERENCES_TABLE;
    runQuery(sql);
    char *implStatements[2] = {(char *)SQL_DROP_IMPLS_TABLE, (char *)SQL_CREATE_IMPLS_TABLE};
    for (int i = 0; i < 2; i++) {
        runQuery(implStatements[i]);
    }
}

char *createInsertQueryForImpl(SymbolPosition impl) {
    static char *statement = NULL;
    if (!statement) {
        statement = (char *)malloc(1000);
    }
    memset(statement, 0, 1000);
    
    sprintf(statement, SQL_INSERT_IMPLS_STATEMENT, impl.symbol, impl.file, impl.row, impl.col);
    return statement;
}

void destroyInsertQuery(char *statement) {
//Since I'm using a static buffer to store the statement now, no need to free it, temporarily.
//    free(statement);
}

int getImplIdBySymbol(const char *symbol) {
    char stmt[500] = {0};
    sprintf(stmt, "SELECT id from oc_impls where function = '%s';", symbol);
    __block int theId = 0;
    runQueryWithHandler(stmt, ^(sqlite3_stmt *statement) {
        theId = sqlite3_column_int(statement, 0);
    });
    return theId;
}

//Insert the symbol to oc_impls table, and return its id
void insertImplItem(SymbolPosition p) {
    char *insert_stmt = createInsertQueryForImpl(p);
    runQuery(insert_stmt);
}

int getOrCreateImplIdForSymbol(char *symbol) {
    int index = getImplIdBySymbol(symbol);
    if (index == 0) {
        SymbolPosition p = {.symbol = symbol, .file="None", .row=0, .col=0};
        insertImplItem(p);
        index = getImplIdBySymbol(symbol);
    }
    return index;
}

char *createInsertQueryForReference(SymbolPosition caller, SymbolPosition callee) {
    static char *statement = NULL;
    if (!statement) {
        statement = (char *)malloc(1000);
    }
    memset(statement, 0, 1000);
    
    int callerId = getImplIdBySymbol(caller.symbol);
    int calleeId = getOrCreateImplIdForSymbol(callee.symbol);
    int callsiteOffsetFromcaller = callee.row - caller.row;
    
    sprintf(statement, SQL_INSERT_REFERENCE_STATEMENT, callerId, calleeId, callsiteOffsetFromcaller);
    return statement;
}


#pragma mark - Indexing related methods

static void freestring(CXString *str) {
    clang_disposeString(*str);
}

static enum CXChildVisitResult ast_visitor(CXCursor cursor,
                                       CXCursor parent,
                                       CXClientData client_data);

static enum CXChildVisitResult methodImplVisitor(CXCursor cursor,
                                                 CXCursor parent,
                                                 CXClientData client_data);

//Find all the objc_msgSend and function calls
static enum CXChildVisitResult functionCallVisitor(CXCursor cursor,
                                                   CXCursor parent,
                                                   CXClientData client_data) {
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
        char *statement = createInsertQueryForReference(caller, callee);
        runQuery(statement);
        destroyInsertQuery(statement);
    }
    return CXChildVisit_Recurse;
}

static SymbolPosition getSymbolPositionFromCursor(const CXCursor cursor) {
    SCOPED_STR(implUSR, clang_getCursorUSR(cursor));
    CXSourceLocation loc = clang_getCursorLocation(cursor);
    CXFile file;
    unsigned row, col, offset;
    clang_getExpansionLocation(loc, &file, &row, &col, &offset);
    SCOPED_STR(fileName, clang_getFileName(file));
    SymbolPosition p = {.file = (char *)fileName, .row = row, .col = col};
    p.symbol = (char *)strdup(implUSR);;
    return p;
}

static enum CXChildVisitResult methodImplVisitor(CXCursor cursor,
                                                 CXCursor parent,
                                                 CXClientData client_data) {
    enum CXCursorKind kind = clang_getCursorKind(cursor);
    //Here find all the method implementations
    if (kind != CXCursor_ObjCInstanceMethodDecl && kind != CXCursor_ObjCClassMethodDecl && kind != CXCursor_ObjCPropertyDecl)
        return CXChildVisit_Recurse;
    
    SymbolPosition p = getSymbolPositionFromCursor(cursor);
    
    if (client_data) {
        //Second pass, visit children
        clang_visitChildren(cursor, functionCallVisitor, &p);
    }
    else {
        //First pass, store the impl to oc_impls
        insertImplItem(p);
    }
    
    if (p.symbol) {
        free(p.symbol);
    }
    return CXChildVisit_Continue;
}

static enum CXChildVisitResult ast_visitor(CXCursor cursor,
                                                 CXCursor parent,
                                                 CXClientData client_data) {
    enum CXCursorKind kind = clang_getCursorKind(cursor);
    
    //Here handle the c function implementations
    if (kind == CXCursor_FunctionDecl) {
        //Only handle the c functions implemented by us
        if (clang_Location_isFromMainFile(clang_getCursorLocation(cursor))) {
            SymbolPosition p = getSymbolPositionFromCursor(cursor);
        
            if (client_data) {
                //Second pass, visit children
                clang_visitChildren(cursor, functionCallVisitor, &p);
            }
            else {
                //First pass, Insert the impl to the table
                insertImplItem(p);
            }
            
            if (p.symbol) {
                free(p.symbol);
            }
        }
        return CXChildVisit_Continue;
    }
    
    //Handle the Objc Impls
    if (kind != CXCursor_ObjCImplementationDecl && kind != CXCursor_ObjCCategoryImplDecl)
        return CXChildVisit_Continue;

    clang_visitChildren(cursor, methodImplVisitor, client_data);
    return CXChildVisit_Recurse;
}

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
    enum CXErrorCode errorCode = clang_parseTranslationUnit2FullArgv(g_clangIndex,
                                                                     mainFile, argv, argc, 0, 0,
                                                                     CXTranslationUnit_Incomplete |
                                                                     CXTranslationUnit_DetailedPreprocessingRecord |
                                                                     CXTranslationUnit_ForSerialization, &translationUnit);
    if (errorCode == CXError_Success) {
        //First pass, record all the implementations to oc_impls table
        clang_visitChildren(clang_getTranslationUnitCursor(translationUnit), ast_visitor, NULL);
        
        BOOL implParse = YES;
        //Second pass, recursively find all the function calls/objc_msgSends and store them to oc_reference table
        clang_visitChildren(clang_getTranslationUnitCursor(translationUnit), ast_visitor, &implParse);
    }
    clang_disposeTranslationUnit(translationUnit);
}

int handle_entry(const char *filepath,
                 const struct stat *info,
                 const int typeflag,
                 struct FTW *pathinfo) {
    if (typeflag == FTW_F) {
        if (strstr(filepath, ".m") || strstr(filepath, ".mm") || strstr(filepath, ".cpp")) {
            printf("Processing %s\n", filepath);
            handleFile(filepath);
        }
    }
    return 0;
}


int handle_directory_tree(const char *const dirpath) {
    int result;
    
    /* Invalid directory path? */
    if (dirpath == NULL || *dirpath == '\0')
        return errno = EINVAL;
    
    result = nftw(dirpath, handle_entry, 20, FTW_PHYS);
    if (result >= 0)
        errno = result;
    
    return errno;
}

void indexAllFilesInDirWithBuildOptionPath(const char *working_dir, const char *buildOptionFilePath) {
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
 
    handle_directory_tree(working_dir);
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
    indexAllFilesInDirWithBuildOptionPath(dir_path, build_option_path);
    closeDB();
    
    return 0;
}
