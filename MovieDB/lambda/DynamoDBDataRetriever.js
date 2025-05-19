const AWS = require('aws-sdk');
const dynamoDB = new AWS.DynamoDB.DocumentClient();

// This Lambda function retrieves the last 20 movies added to the DynamoDB table "TopMovies" within the last 24 hours
exports.handler = async (event) => {
    const currentTime = new Date();
    const past24Hours = new Date(currentTime.getTime() - 24 * 60 * 60 * 1000).toISOString();

    const params = {
        TableName: "TopMovies",
        FilterExpression: "created_at >= :past24Hours",
        ExpressionAttributeValues: {
            ":past24Hours": past24Hours
        },
    };

    try {
        const data = await dynamoDB.scan(params).promise();

        // Get the last 20 movies
        const movies = data.Items.slice(-20);

        return {
            statusCode: 200,
            body: JSON.stringify(movies),
        };
    } catch (error) {
        console.error("Error retrieving movie data:", error);
        return {
            statusCode: 500,
            body: JSON.stringify({ message: "Error retrieving movie data", error: error.message }),
        };
    }
};
