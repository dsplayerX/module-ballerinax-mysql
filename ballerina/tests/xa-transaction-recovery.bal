import ballerina/os;
import ballerina/test;

@test:Config {
}
function testXARecovery() returns error? {

    // create a broken transaction (prepared, awaitng decision) in the database
    os:Process exec1 = check os:exec({
        value: "docker",
        arguments: ["exec", "ballerina-mysql-trx", "mysql", "-uroot", "-pmy-secret-pw", "-e", "XA START '00000000-0000-0000-0000-000000000001','1',1111575552; INSERT INTO XA_TRANSACTION_1.CustomersTrx (customerId, name, creditLimit, country) values (99, 'Anne', 1000, 'UK'); XA END '00000000-0000-0000-0000-000000000001','1',1111575552; XA PREPARE '00000000-0000-0000-0000-000000000001','1',1111575552;"]
    });

    int status = check exec1.waitForExit();
    if (status != 0) {
        return error("Failed to create a broken transaction in the database");
    }

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
        _ = check dbClient1->execute(`insert into CustomersTrx (customerId, name, creditLimit, country)
                                values (10, 'Frank', 2000, 'USA')`);
        _ = check dbClient2->execute(`insert into Salary (id, value ) values (1, 1000)`);
        check commit;
    }

    int count1 = check getCustomerTrxCount(dbClient1, 69);
    test:assertEquals(count1, 1, "Recovery failed in first database");

    check dbClient1.close();
    check dbClient2.close();
}
