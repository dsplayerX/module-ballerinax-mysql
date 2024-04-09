// Copyright (c) 2020 WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/test;
import ballerina/sql;

string xaTransactionDB1 = "XA_TRANSACTION_1";
string xaTransactionDB2 = "XA_TRANSACTION_2";
int dbClient2Port = 3304;

type XAResultCount record {
    int COUNTVAL;
};

@test:Config {
    groups: ["transaction", "xa-transaction"]
}
function testXATransactionRecovery() returns error? {
    Client dbClient1 = check new (host, user, password, xaTransactionDB1, port,
        connectionPool = {maxOpenConnections: 1},
        options = {useXADatasource: true}
    );
    Client dbClient2 = check new (host, user, password, xaTransactionDB2, port,
        connectionPool = {maxOpenConnections: 1},
        options = {useXADatasource: true}
    );

    // create a broken transaction (prepared, awaitng decision) in the database
    

    transaction {
        _ = check dbClient1->execute(`insert into CustomersTrx (customerId, name, creditLimit, country)
                                values (2, 'Frank', 2000, 'USA')`);
        _ = check dbClient2->execute(`insert into SalaryTrx (id, value ) values (2, 2000)`);
        check commit;
    } 

    int count1 = check getCustomerCount(dbClient1, 69);
    int count2 = check getSalaryCount(dbClient2, 69);
    test:assertEquals(count1, 1, "Recovery failed in first database");
    test:assertEquals(count2, 1, "Recovery failed in second database");

    check dbClient1.close();
    check dbClient2.close();
}


@test:Config {
    groups: ["transaction", "xa-transaction"]
}
function testXATransactionSuccess() returns error? {
    Client dbClient1 = check new (host, user, password, xaTransactionDB1, port,
                                    connectionPool = {maxOpenConnections: 1},
                                    options = {
                                        ssl: {
                                                allowPublicKeyRetrieval: true
                                            },
                                            useXADatasource: true
                                    }
                                   );
    Client dbClient2 = check new (host, user, password, xaTransactionDB2, dbClient2Port,
                                            connectionPool = {maxOpenConnections: 1},
                                            options = {
                                                ssl: {
                                                    allowPublicKeyRetrieval: true
                                                },
                                                useXADatasource: true
                                            }
                                            );

    transaction {
        _ = check dbClient1->execute(`insert into Customers (customerId, name, creditLimit, country)
                                values (1, 'Anne', 1000, 'UK')`);
        _ = check dbClient2->execute(`insert into Salary (id, value ) values (1, 1000)`);
        check commit;
    } on fail {
        test:assertFail(msg = "Transaction failed");
    }

    int count1 = check getCustomerCount(dbClient1, 1);
    int count2 = check getSalaryCount(dbClient2, 1);
    test:assertEquals(count1, 1, "First transaction failed");
    test:assertEquals(count2, 1, "Second transaction failed");

    check dbClient1.close();
    check dbClient2.close();
}

@test:Config {
    groups: ["transaction", "xa-transaction"]
}
function testXATransactionFailureWithDataSource() returns error? {
    Client dbClient1 = check new (host, user, password, xaTransactionDB1, port,
                                    connectionPool = {maxOpenConnections: 1},
                                    options = {
                                        ssl: {
                                            allowPublicKeyRetrieval: true
                                        },
                                        useXADatasource: true
                                    }
                                  );
    Client dbClient2 = check new (host, user, password, xaTransactionDB2, dbClient2Port,
                                        connectionPool = {maxOpenConnections: 1},
                                        options = {
                                            ssl: {
                                                allowPublicKeyRetrieval: true
                                            },
                                            useXADatasource: true
                                        }
                                       );

    transaction {
        // Intentionally fail first statement
        _ = check dbClient1->execute(`insert into CustomersTrx (customerId, name, creditLimit, country)
                                values (30, 'Anne', 1000, 'UK')`);
        _ = check dbClient2->execute(`insert into Salary (id, value ) values (10, 1000)`);
        check commit;
    } on fail error e {
        test:assertTrue(e.message().includes("Duplicate"), msg = "Transaction failed as expected");
    }

    int count1 = check getCustomerTrxCount(dbClient1, 30);
    int count2 = check getSalaryCount(dbClient2, 20);
    test:assertEquals(count1, 1, "First transaction should have failed");
    test:assertEquals(count2, 0, "Second transaction should not have been executed");

    check dbClient1.close();
    check dbClient2.close();
}

@test:Config {
    groups: ["transaction", "xa-transaction"]
}
function testXATransactionPartialSuccessWithDataSource() returns error? {
    Client dbClient1 = check new (host, user, password, xaTransactionDB1, port,
                                    connectionPool = {maxOpenConnections: 1},
                                    options = {
                                        ssl: {
                                            allowPublicKeyRetrieval: true
                                        },
                                        useXADatasource: true
                                    }
                                   );
    Client dbClient2 = check new (host, user, password, xaTransactionDB2, dbClient2Port,
                                        connectionPool = {maxOpenConnections: 1},
                                        options = {
                                            ssl: {
                                                allowPublicKeyRetrieval: true
                                            },
                                            useXADatasource: true
                                        }
                                        );

    transaction {
        _ = check dbClient1->execute(`insert into Customers (customerId, name, creditLimit, country)
                                values (30, 'Anne', 1000, 'UK')`);
        // Intentionally fail second statement
        _ = check dbClient2->execute(`insert into SalaryTrx (id, value ) values (20, 1000)`);
        check commit;
    } on fail error e {
        test:assertTrue(e.message().includes("Duplicate"), msg = "Transaction failed as expected");
    }

    int count1 = check getCustomerCount(dbClient1, 30);
    int count2 = check getSalaryTrxCount(dbClient2, 20);
    test:assertEquals(count1, 0, "First transaction is not rolledback");
    test:assertEquals(count2, 1, "Second transaction has succeeded");

    check dbClient1.close();
    check dbClient2.close();
}

isolated function getCustomerCount(Client dbClient, int id) returns int|error {
    stream<XAResultCount, sql:Error?> streamData = dbClient->query(`Select COUNT(*) as
        countVal from Customers where customerId = ${id}`);
    return getResult(streamData);
}

isolated function getCustomerTrxCount(Client dbClient, int id) returns int|error {
    stream<XAResultCount, sql:Error?> streamData = dbClient->query(`Select COUNT(*) as
        countVal from CustomersTrx where customerId = ${id}`);
    return getResult(streamData);
}

isolated function getSalaryCount(Client dbClient, int id) returns int|error {
    stream<XAResultCount, sql:Error?> streamData = dbClient->query(`Select COUNT(*) as countval
    from Salary where id = ${id}`);
    return getResult(streamData);
}

isolated function getSalaryTrxCount(Client dbClient, int id) returns int|error {
    stream<XAResultCount, sql:Error?> streamData = dbClient->query(`Select COUNT(*) as countval
    from SalaryTrx where id = ${id}`);
    return getResult(streamData);
}

isolated function getResult(stream<XAResultCount, sql:Error?> streamData) returns int|error {
    record {|XAResultCount value;|}? data = check streamData.next();
    check streamData.close();
    XAResultCount? value = data?.value;
    if value is XAResultCount {
        return value.COUNTVAL;
    }
    return 0;
}
