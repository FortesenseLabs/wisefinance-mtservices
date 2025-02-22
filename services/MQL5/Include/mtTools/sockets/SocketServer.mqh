
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Fortesense Labs."
#property link "https://www.github.com/FortesenseLabs"
#property version "0.10"

#include <mtTools/sockets/Socketlib.mqh>
#include <mtTools/sockets/SocketFunctions.mqh>
#include <mtTools/Types.mqh>
#include <mtTools/formats/Json.mqh>
#include <mtTools/Utils.mqh>
#include <mtTools/AppErrors.mqh>

// Sockets
SOCKET64 serverSocket = INVALID_SOCKET64;
ClientSocket clients[4];  // 1024

//+------------------------------------------------------------------+
//| StartServer                                                        |
//+------------------------------------------------------------------+
void StartServer(string addr, ushort port)
{
  // Initialize the library
  char wsaData[];
  ArrayResize(wsaData, sizeof(WSAData));
  int res = WSAStartup(MAKEWORD(2, 2), wsaData);
  if (res != 0)
  {
    Print("-WSAStartup failed error: " + string(res));
    return;
  }

  // Create a socket
  serverSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (serverSocket == INVALID_SOCKET64)
  {
    Print("-Create failed error: " + WSAErrorDescript(WSAGetLastError()));
    CloseServer();
    return;
  }

  // Bind to address and port
  Print("Trying to bind " + addr + ":" + string(port));

  char ch[];
  StringToCharArray(addr, ch);
  sockaddr_in addrin;
  addrin.sin_family = AF_INET;
  addrin.sin_addr.u.S_addr = inet_addr(ch);
  addrin.sin_port = htons(port);
  ref_sockaddr ref;
  ref.in = addrin;
  if (bind(serverSocket, ref.ref, sizeof(addrin)) == SOCKET_ERROR)
  {
    int err = WSAGetLastError();
    if (err != WSAEISCONN)
    {
      Print("-Connect failed error: " + WSAErrorDescript(err) + ". Cleanup socket");
      CloseServer();
      return;
    }
  }

  // Set to non-blocking mode
  int non_block = 1;
  res = ioctlsocket(serverSocket, (int)FIONBIO, non_block);
  if (res != NO_ERROR)
  {
    Print("ioctlsocket failed error: " + string(res));
    CloseServer();
    return;
  }

  // Listen on the port and accept client connections
  if (listen(serverSocket, SOMAXCONN) == SOCKET_ERROR)
  {
    Print("Listen failed with error: ", WSAErrorDescript(WSAGetLastError()));
    CloseServer();
    return;
  }

  Print("Server started successfully");
  Print("Listening on " + addr + ":" + string(port));
}

//+------------------------------------------------------------------+
//| CloseServer                                                        |
//+------------------------------------------------------------------+
void CloseServer()
{
  // Close all client sockets
  for (int i = 0; i < ArraySize(clients); i++)
  {
    if (clients[i].socket != INVALID_SOCKET64)
    {
      // Reset
      // ResetSubscriptionsAndIndicators(clients[i]);

      closesocket(clients[i].socket);
      clients[i].socket = INVALID_SOCKET64;
    }
  }

  // Close the server socket
  if (serverSocket != INVALID_SOCKET64)
  {
    closesocket(serverSocket);
    serverSocket = INVALID_SOCKET64;
  }

  // Clean up Winsock
  WSACleanup();
}

//+------------------------------------------------------------------+
//| AcceptClients                                                    |
//+------------------------------------------------------------------+
void AcceptClients()
{
  if (serverSocket == INVALID_SOCKET64)
  {
    return;
  }

  // Accept any new incoming connections
  SOCKET64 client = INVALID_SOCKET64;

  ref_sockaddr ch;
  int len = sizeof(ref_sockaddr);
  client = accept(serverSocket, ch.ref, len);
  if (client != INVALID_SOCKET64)
  {
    // Add the new client socket to the list of clients
    for (int i = 0; i < ArraySize(clients); i++)
    {
      if (clients[i].socket == INVALID_SOCKET64)
      {
        clients[i].socket = client;
        clients[i] = SocketRecv(clients[i]);
        break;
      }
    }
  }

  // Check for data from any of the clients
  for (int i = 0; i < ArraySize(clients); i++)
  {
    if (clients[i].socket != INVALID_SOCKET64)
    {
      clients[i] = SocketRecv(clients[i]);
      ProcessClientRequest(clients[i]);
    }
  }

  // Print("Waiting for Connections!!!");
}

//+------------------------------------------------------------------+
//| Process Client Request and Respond                                |
//+------------------------------------------------------------------+
void ProcessClientRequest(ClientSocket &client)
{
  // char buffer[SOCK_BUF];
  // int bytesRead = recv(clientSocket, buffer, sizeof(buffer), 0);
  // client = SocketRecv(client);

  if (client.socket <= 0 || client.socket == INVALID_SOCKET64)
  {
    // Error or connection closed
    closesocket(client.socket);
    return;
  }

  RequestHandler(client);
}

//+------------------------------------------------------------------+
//| parse request data, convert into struct                          |
//+------------------------------------------------------------------+
RequestData ParseRequestData(ClientSocket &client)
{
  Print("Request Data: ", client.requestData);

  CJAVal dataObject;

  if (StringLen(client.requestData) > 0 && !dataObject.Deserialize(client.requestData))
  {
    Print("Failed to deserialize request command");
    mControl.mSetUserError(65537, GetErrorType(65537));
    CheckError(client, __FUNCTION__);
  }

  RequestData reqData;

  // Validate
  if (dataObject["toDate"].ToInt() != NULL)
  {
    datetime toDate = (datetime)dataObject["toDate"].ToInt();
  }

  datetime fromDate = (datetime)dataObject["fromDate"].ToInt();
  datetime toDate = TimeCurrent();

  // Unwrap remaining request data
  reqData.action = (string)dataObject["action"].ToStr();
  reqData.actionType = (string)dataObject["actionType"].ToStr();
  reqData.symbol = (string)dataObject["symbol"].ToStr();
  reqData.chartTimeFrame = (string)dataObject["chartTimeFrame"].ToStr();
  reqData.fromDate = fromDate;
  reqData.toDate = toDate;

  // Set optional request data to empty strings
  reqData.id = (ulong)dataObject["id"].ToStr(); // .ToInt()
  reqData.magic = (string)dataObject["magic"].ToStr();
  reqData.volume = (double)dataObject["volume"].ToDbl();
  reqData.price = (double)NormalizeDouble(dataObject["price"].ToDbl(), _Digits);
  reqData.stoploss = (double)dataObject["stoploss"].ToDbl();
  reqData.takeprofit = (double)dataObject["takeprofit"].ToDbl();
  reqData.expiration = (int)dataObject["expiration"].ToInt();
  reqData.deviation = (double)dataObject["deviation"].ToDbl();
  reqData.comment = (string)dataObject["comment"].ToStr();
  reqData.chartId = "";
  reqData.indicatorChartId = "";
  reqData.chartIndicatorSubWindow = "";
  reqData.style = "";

  return reqData;
}

//+------------------------------------------------------------------+
//| parse request data, convert into string                          |
//+------------------------------------------------------------------+
string ParseRequestCommand(ClientSocket &client)
{
  Print("Request Data: ", client.requestData);

  string errMessage;

  if (StringLen(client.requestData) == 0)
  {
    SendErrorMessage(client, 09104, "empty command");

    // Close the client socket
    closesocket(client.socket);

    return errMessage;
  }

  string commandString[]; // An array to get strings
  string sep = "|";       // A separator as a character
  ushort u_sep;           // The code of the separator character

  //--- Get the separator code
  u_sep = StringGetCharacter(sep, 0);

  //--- Split the string to substrings
  int k = StringSplit(client.requestData, u_sep, commandString);

  PrintFormat("Strings obtained: %d. Used separator '%s' with the code %d", k, sep, u_sep);

  // check authorization code
  if (commandString[ArraySize(commandString) - 1] != AUTHORIZATION_CODE + "\r\n")
  {
    SendErrorMessage(client, 99900, "unauthorized");

    // Close the client socket
    closesocket(client.socket);

    return errMessage;
  }

  return commandString[0];
}
