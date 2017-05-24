{******************************************************************************}
{                                                                              }
{       Delphi cross platform socket library                                   }
{                                                                              }
{       Copyright (c) 2017 WiNDDRiVER(soulawing@gmail.com)                     }
{                                                                              }
{       Homepage: https://github.com/winddriver/Delphi-Cross-Socket            }
{                                                                              }
{******************************************************************************}
unit Net.CrossSocket.IocpLoop;

interface

uses
  System.SysUtils, System.Classes, Net.SocketAPI, Net.CrossSocket.EventLoop,
  Winapi.Windows, Net.Winsock2, Net.Wship6;

type
  TIocpLoop = class(TAbstractEventLoop)
  private const
    SHUTDOWN_FLAG = ULONG_PTR(-1);
    SO_UPDATE_CONNECT_CONTEXT = $7010;
  private type
    TAddrUnion = record
      case Integer of
        0: (IPv4: TSockAddrIn);
        1: (IPv6: TSockAddrIn6);
    end;

    TAddrBuffer = record
      Addr: TAddrUnion;
      Extra: array [0..15] of Byte;
    end;

    TAcceptExBuffer = array[0..SizeOf(TAddrBuffer) * 2 - 1] of Byte;

    TPerIoBufUnion = record
      case Integer of
        0: (DataBuf: WSABUF);
        // ���Bufferֻ����AcceptEx�����ն˵�ַ���ݣ���СΪ2����ַ�ṹ
        1: (AcceptExBuffer: TAcceptExBuffer);
    end;

    TIocpAction = (ioAccept, ioConnect, ioReadZero, ioSend);

    PPerIoData = ^TPerIoData;
    TPerIoData = record
      Overlapped: TWSAOverlapped;
      Buffer: TPerIoBufUnion;
      Action: TIocpAction;
      Socket: THandle;
      Callback: TProc<THandle, Boolean>;

      case Integer of
        1: (Accept:
              record
                ai_family, ai_socktype, ai_protocol: Integer;
              end);
    end;
  private
    FIocpHandle: THandle;
    FIoThreads: TArray<TIoEventThread>;
    FIoThreadHandles: TArray<THandle>;

    function NewIoData: PPerIoData;
    procedure FreeIoData(P: PPerIoData);

    procedure NewAccept(ASocket: THandle; ai_family, ai_socktype, ai_protocol: Integer);
    function NewReadZero(ASocket: THandle): Boolean;

    procedure RequestAcceptComplete(ASocket: THandle; APerIoData: PPerIoData);
    procedure RequestConnectComplete(ASocket: THandle; APerIoData: PPerIoData);
    procedure RequestReadZeroComplete(ASocket: THandle; APerIoData: PPerIoData);
    procedure RequestSendComplete(ASocket: THandle; APerIoData: PPerIoData);
  protected
    procedure TriggerConnected(ASocket: THandle; AConnectType: Integer); override;
    procedure TriggerDisconnected(ASocket: THandle); override;

    procedure StartLoop; override;
    procedure StopLoop; override;

    function Listen(const AHost: string; APort: Word;
      const ACallback: TProc<THandle, Boolean> = nil): Integer; override;
    function Connect(const AHost: string; APort: Word;
      const ACallback: TProc<THandle, Boolean> = nil): Integer; override;
    function Send(ASocket: THandle; const ABuf; ALen: Integer;
      const ACallback: TProc<THandle, Boolean> = nil): Integer; override;

    function ProcessIoEvent: Boolean; override;
  end;

implementation

{ TIocpLoop }

function TIocpLoop.NewIoData: PPerIoData;
begin
  System.New(Result);
  FillChar(Result^, SizeOf(TPerIoData), 0);
end;

procedure TIocpLoop.FreeIoData(P: PPerIoData);
begin
  System.Dispose(P);
end;

procedure TIocpLoop.NewAccept(ASocket: THandle; ai_family, ai_socktype,
  ai_protocol: Integer);
var
  LClientSocket: THandle;
  LPerIoData: PPerIoData;
  LBytes: Cardinal;
begin
  LClientSocket := WSASocket(ai_family, ai_socktype, ai_protocol, nil, 0, WSA_FLAG_OVERLAPPED);
  if (LClientSocket = INVALID_SOCKET) then
  begin
    {$IFDEF DEBUG}
    __RaiseLastOSError;
    {$ENDIF}
    Exit;
  end;

  TSocketAPI.SetNonBlock(LClientSocket, True);
  TSocketAPI.SetReUseAddr(LClientSocket, True);
  SetKeepAlive(LClientSocket);

  LPerIoData := NewIoData;
  LPerIoData.Action := ioAccept;
  LPerIoData.Socket := LClientSocket;
  LPerIoData.Accept.ai_family := ai_family;
  LPerIoData.Accept.ai_socktype := ai_socktype;
  LPerIoData.Accept.ai_protocol := ai_protocol;
  if (not AcceptEx(ASocket, LClientSocket, @LPerIoData.Buffer.AcceptExBuffer, 0,
    SizeOf(TAddrBuffer), SizeOf(TAddrBuffer), LBytes, POverlapped(LPerIoData)))
    and (WSAGetLastError <> WSA_IO_PENDING) then
  begin
    {$IFDEF DEBUG}
    __RaiseLastOSError;
    {$ENDIF}
    TSocketAPI.CloseSocket(LClientSocket);
    FreeIoData(LPerIoData);
  end;
end;

function TIocpLoop.NewReadZero(ASocket: THandle): Boolean;
var
  LPerIoData: PPerIoData;
  LBytes, LFlags: Cardinal;
begin
  LPerIoData := NewIoData;
  LPerIoData.Buffer.DataBuf.buf := nil;
  LPerIoData.Buffer.DataBuf.len := 0;
  LPerIoData.Action := ioReadZero;
  LPerIoData.Socket := ASocket;

  LFlags := 0;
  LBytes := 0;
  if (WSARecv(ASocket, @LPerIoData.Buffer.DataBuf, 1, LBytes, LFlags, PWSAOverlapped(LPerIoData), nil) < 0)
    and (WSAGetLastError <> WSA_IO_PENDING) then
  begin
    FreeIoData(LPerIoData);
    Exit(False);
  end;

  Result := True;
end;

procedure TIocpLoop.RequestAcceptComplete(ASocket: THandle;
  APerIoData: PPerIoData);
begin
  NewAccept(ASocket, APerIoData.Accept.ai_family, APerIoData.Accept.ai_socktype,
    APerIoData.Accept.ai_protocol);

  if (TSocketAPI.SetSockOpt(APerIoData.Socket, SOL_SOCKET,
    SO_UPDATE_ACCEPT_CONTEXT, ASocket, SizeOf(THandle)) < 0) then
  begin
    {$IFDEF DEBUG}
    __RaiseLastOSError;
    {$ENDIF}
    TSocketAPI.CloseSocket(APerIoData.Socket);
    Exit;
  end;

  if (CreateIoCompletionPort(APerIoData.Socket, FIocpHandle, ULONG_PTR(APerIoData.Socket), 0) = 0) then
  begin
    {$IFDEF DEBUG}
    __RaiseLastOSError;
    {$ENDIF}
    TSocketAPI.CloseSocket(APerIoData.Socket);
    Exit;
  end;

  if NewReadZero(APerIoData.Socket) then
    TriggerConnected(APerIoData.Socket, CT_ACCEPT)
  else
    TSocketAPI.CloseSocket(APerIoData.Socket);
end;

procedure TIocpLoop.RequestConnectComplete(ASocket: THandle;
  APerIoData: PPerIoData);
var
  LOptVal: Integer;

  procedure _Success;
  begin
    TriggerConnected(ASocket, CT_CONNECT);

    if Assigned(APerIoData.Callback) then
      APerIoData.Callback(ASocket, True);
  end;

  procedure _Failed;
  begin
    {$IFDEF DEBUG}
    __RaiseLastOSError;
    {$ENDIF}
    TSocketAPI.CloseSocket(ASocket);

    TriggerConnectFailed(ASocket);

    if Assigned(APerIoData.Callback) then
      APerIoData.Callback(ASocket, False);
  end;

begin
  if (TSocketAPI.GetError(ASocket) <> 0) then
  begin
    _Failed;
    Exit;
  end;

  // �����øò���, �ᵼ�� getpeername ����ʧ��
  LOptVal := 1;
  if (TSocketAPI.SetSockOpt(ASocket, SOL_SOCKET,
    SO_UPDATE_CONNECT_CONTEXT, LOptVal, SizeOf(Integer)) < 0) then
  begin
    _Failed;
    Exit;
  end;

  if NewReadZero(ASocket) then
    _Success
  else
    _Failed;
end;

procedure TIocpLoop.RequestReadZeroComplete(ASocket: THandle;
  APerIoData: PPerIoData);
var
  LRcvd: Integer;
begin
  while True do
  begin
    LRcvd := TSocketAPI.Recv(ASocket, FRecvBuf[0], RCV_BUF_SIZE);

    // �Է������Ͽ�����
    if (LRcvd = 0) then
    begin
      if (TSocketAPI.CloseSocket(ASocket) = 0) then
        TriggerDisconnected(ASocket);
      Exit;
    end;

    if (LRcvd < 0) then
    begin
      // ��Ҫ����
      if _Again(GetLastError) then Break;

      if (TSocketAPI.CloseSocket(ASocket) = 0) then
        TriggerDisconnected(ASocket);

      Exit;
    end;

    TriggerReceived(ASocket, @FRecvBuf[0], LRcvd);

    if (LRcvd < RCV_BUF_SIZE) then Break;
  end;

  if not NewReadZero(ASocket) then
  begin
    if (TSocketAPI.CloseSocket(ASocket) = 0) then
      TriggerDisconnected(ASocket);
  end;
end;

procedure TIocpLoop.RequestSendComplete(ASocket: THandle;
  APerIoData: PPerIoData);
begin
  if Assigned(APerIoData.Callback) then
    APerIoData.Callback(ASocket, True);
end;

procedure TIocpLoop.StartLoop;
var
  I: Integer;
begin
  if (FIoThreads <> nil) then Exit;

  FIocpHandle := CreateIoCompletionPort(INVALID_HANDLE_VALUE, 0, 0, 0);
  SetLength(FIoThreads, GetIoThreads);
  SetLength(FIoThreadHandles, Length(FIoThreads));
  for I := 0 to Length(FIoThreads) - 1 do
  begin
    FIoThreads[I] := TIoEventThread.Create(Self);
    FIoThreadHandles[I] := FIoThreads[I].Handle;
  end;
end;

procedure TIocpLoop.StopLoop;
var
  I: Integer;
begin
  if (FIoThreads = nil) then Exit;

  CloseAll;

  while (FListensCount > 0) or (FConnectionsCount > 0) do Sleep(1);

  for I := 0 to Length(FIoThreads) - 1 do
    PostQueuedCompletionStatus(FIocpHandle, 0, 0, POverlapped(SHUTDOWN_FLAG));
  WaitForMultipleObjects(Length(FIoThreadHandles), Pointer(FIoThreadHandles), True, INFINITE);
  CloseHandle(FIocpHandle);
  for I := 0 to Length(FIoThreads) - 1 do
    FreeAndNil(FIoThreads[I]);
  FIoThreads := nil;
  FIoThreadHandles := nil;
end;

procedure TIocpLoop.TriggerConnected(ASocket: THandle; AConnectType: Integer);
begin
end;

procedure TIocpLoop.TriggerDisconnected(ASocket: THandle);
begin
end;

function TIocpLoop.Connect(const AHost: string; APort: Word;
  const ACallback: TProc<THandle, Boolean>): Integer;
  procedure _Failed1;
  begin
    TriggerConnectFailed(INVALID_HANDLE_VALUE);
    if Assigned(ACallback) then
      ACallback(INVALID_HANDLE_VALUE, False);
  end;

  function _Connect(ASocket: THandle; Addr: PRawAddrInfo): Boolean;
    procedure _Failed2;
    begin
      TSocketAPI.CloseSocket(ASocket);
      TriggerConnectFailed(ASocket);
      if Assigned(ACallback) then
        ACallback(ASocket, False);
    end;
  var
    LSockAddr: TRawSockAddrIn;
    LPerIoData: PPerIoData;
    LBytes: Cardinal;
  begin
    LSockAddr.AddrLen := Addr.ai_addrlen;
    Move(Addr.ai_addr^, LSockAddr.Addr, Addr.ai_addrlen);
    if (Addr.ai_family = AF_INET6) then
    begin
      LSockAddr.Addr6.sin6_addr := in6addr_any;
      LSockAddr.Addr6.sin6_port := 0;
    end else
    begin
      LSockAddr.Addr.sin_addr.S_addr := INADDR_ANY;
      LSockAddr.Addr.sin_port := 0;
    end;
    if (TSocketAPI.Bind(ASocket, @LSockAddr.Addr, LSockAddr.AddrLen) < 0) then
    begin
      _Failed2;
      Exit(False);
    end;

    if (CreateIoCompletionPort(ASocket, FIocpHandle, ULONG_PTR(ASocket), 0) = 0) then
    begin
      _Failed2;
      Exit(False);
    end;

    LPerIoData := NewIoData;
    LPerIoData.Action := ioConnect;
    LPerIoData.Socket := ASocket;
    LPerIoData.Callback := ACallback;
    if not ConnectEx(ASocket, Addr.ai_addr, Addr.ai_addrlen, nil, 0, LBytes, PWSAOverlapped(LPerIoData)) and
      (WSAGetLastError <> WSA_IO_PENDING) then
    begin
      FreeIoData(LPerIoData);
      _Failed2;
      Exit(False);
    end;

    Result := True;
  end;
var
  LHints: TRawAddrInfo;
  P, LAddrInfo: PRawAddrInfo;
  LSocket: THandle;
begin
  FillChar(LHints, SizeOf(TRawAddrInfo), 0);
  LHints.ai_family := AF_UNSPEC;
  LHints.ai_socktype := SOCK_STREAM;
  LHints.ai_protocol := IPPROTO_TCP;
  LAddrInfo := TSocketAPI.GetAddrInfo(AHost, APort, LHints);
  if (LAddrInfo = nil) then
  begin
    _Failed1;
    Exit(-1);
  end;

  P := LAddrInfo;
  try
    while (LAddrInfo <> nil) do
    begin
      LSocket := WSASocket(LAddrInfo.ai_family, LAddrInfo.ai_socktype,
        LAddrInfo.ai_protocol, nil, 0, WSA_FLAG_OVERLAPPED);
      if (LSocket = INVALID_SOCKET) then
      begin
        _Failed1;
        Exit(-1);
      end;

      TSocketAPI.SetNonBlock(LSocket, True);
      TSocketAPI.SetReUseAddr(LSocket, True);
      SetKeepAlive(LSocket);

      if _Connect(LSocket, LAddrInfo) then Exit(0);

      LAddrInfo := PRawAddrInfo(LAddrInfo.ai_next);
    end;
  finally
    TSocketAPI.FreeAddrInfo(P);
  end;

  _Failed1;
  Result := -1;
end;

function TIocpLoop.Listen(const AHost: string; APort: Word;
  const ACallback: TProc<THandle, Boolean>): Integer;
var
  LHints: TRawAddrInfo;
  P, LAddrInfo: PRawAddrInfo;
  LSocket: THandle;
  I: Integer;

  procedure _Failed;
  begin
    if (LSocket <> INVALID_HANDLE_VALUE) then
      TSocketAPI.CloseSocket(LSocket);

    if Assigned(ACallback) then
      ACallback(LSocket, False);
  end;

  procedure _Success;
  begin
    if Assigned(ACallback) then
      ACallback(LSocket, True);

    TriggerListened(LSocket);
  end;

begin
  LSocket := INVALID_SOCKET;
  FillChar(LHints, SizeOf(TRawAddrInfo), 0);

  LHints.ai_flags := AI_PASSIVE;
  LHints.ai_family := AF_UNSPEC;
  LHints.ai_socktype := SOCK_STREAM;
  LHints.ai_protocol := IPPROTO_TCP;
  LAddrInfo := TSocketAPI.GetAddrInfo(AHost, APort, LHints);
  if (LAddrInfo = nil) then
  begin
    _Failed;
    Exit(-1);
  end;

  P := LAddrInfo;
  try
    while (LAddrInfo <> nil) do
    begin
      LSocket := WSASocket(LAddrInfo.ai_family, LAddrInfo.ai_socktype,
        LAddrInfo.ai_protocol, nil, 0, WSA_FLAG_OVERLAPPED);
      if (LSocket = INVALID_SOCKET) then
      begin
        {$IFDEF DEBUG}
        __RaiseLastOSError;
        {$ENDIF}
        _Failed;
        Exit(-1);
      end;

      TSocketAPI.SetNonBlock(LSocket, True);
      TSocketAPI.SetReUseAddr(LSocket, True);

      if (TSocketAPI.Bind(LSocket, LAddrInfo.ai_addr, LAddrInfo.ai_addrlen) < 0) then
      begin
        {$IFDEF DEBUG}
        __RaiseLastOSError;
        {$ENDIF}
        _Failed;
        Exit(-1);
      end;

      if (TSocketAPI.Listen(LSocket) < 0) then
      begin
        _Failed;
        Exit(-1);
      end;

      if (CreateIoCompletionPort(LSocket, FIocpHandle, ULONG_PTR(LSocket), 0) = 0) then
      begin
        {$IFDEF DEBUG}
        __RaiseLastOSError;
        {$ENDIF}
        _Failed;
        Exit(-1);
      end;

      // ��ÿ��IO�߳�Ͷ��һ��AcceptEx
      for I := 1 to GetIoThreads do
        NewAccept(LSocket, LAddrInfo.ai_family, LAddrInfo.ai_socktype, LAddrInfo.ai_protocol);

      _Success;

      // ����˿ڴ���0�������е�ַͳһ���׸����䵽�Ķ˿�
      if (APort = 0) and (LAddrInfo.ai_next <> nil) then
        LAddrInfo.ai_next.ai_addr.sin_port := LAddrInfo.ai_addr.sin_port;

      LAddrInfo := PRawAddrInfo(LAddrInfo.ai_next);
    end;
  finally
    TSocketAPI.FreeAddrInfo(P);
  end;

  Result := 0;
end;

function TIocpLoop.Send(ASocket: THandle; const ABuf; ALen: Integer;
  const ACallback: TProc<THandle, Boolean>): Integer;
var
  LPerIoData: PPerIoData;
  LBytes, LFlags: Cardinal;
begin
  LPerIoData := NewIoData;
  LPerIoData.Buffer.DataBuf.buf := @ABuf;
  LPerIoData.Buffer.DataBuf.len := ALen;
  LPerIoData.Action := ioSend;
  LPerIoData.Socket := ASocket;
  LPerIoData.Callback := ACallback;

  LFlags := 0;
  LBytes := 0;
  // WSASend ������ֲ��ַ��͵����, Ҫôȫ��ʧ��, Ҫôȫ���ɹ�
  // ���Բ���Ҫ�� kqueue �� epoll �е��� send ����������֮�󻹵ü��ʵ�ʷ����˶���
  // Ψһ��Ҫע�����: WSASend �Ὣ�����͵�������������ҳ���ڴ�, ��ҳ���ڴ���Դ
  // �Ƿǳ����ŵ�, ���Բ�Ҫ�޽��Ƶĵ��� WSASend, ���ͨ���ص�������һ�������ټ�
  // ��������һ��
  if (WSASend(ASocket, @LPerIoData.Buffer.DataBuf, 1, LBytes, LFlags, PWSAOverlapped(LPerIoData), nil) < 0)
    and (WSAGetLastError <> WSA_IO_PENDING) then
  begin
    if Assigned(ACallback) then
      ACallback(ASocket, False);

    // �������� WSAENOBUFS, Ҳ����Ͷ�ݵ� WSASend ����, ����������
    // ���·�ҳ���ڴ���Դȫ��������, Ҫ����������������ϲ㷢���߼�
    // ��֤�����޽��Ƶĵ���Send���ʹ�������, ��÷�����һ���ټ�����
    // һ��, �������ṩ�˷��ͽ���Ļص�����, �ڻص��������淢�ͳɹ�
    // ֮��Ϳ��Լ�����һ�����ݷ�����
    FreeIoData(LPerIoData);
    if (TSocketAPI.CloseSocket(ASocket) = 0) then
      TriggerDisconnected(ASocket);
    Exit(-1);
  end;

  Result := ALen;
end;

function TIocpLoop.ProcessIoEvent: Boolean;
var
  LBytes: Cardinal;
  LSocket: THandle;
  LPerIoData: PPerIoData;
begin
  if not GetQueuedCompletionStatus(FIocpHandle, LBytes, ULONG_PTR(LSocket), POverlapped(LPerIoData), INFINITE) then
  begin
    // ������, �����������Ҳ���ǿյ�,
    // ���������������, Ӧ��Ҳ���������, ���������ֹIO�߳�
    if (LSocket = 0) or (LPerIoData = nil) then
    begin
      {$IFDEF DEBUG}
      __RaiseLastOSError;
      {$ENDIF}
      Exit(False);
    end;

    try
      case LPerIoData.Action of
        ioAccept:
          // WSA_OPERATION_ABORTED, 995, �����߳��˳���Ӧ�ó�����������ֹ I/O ������
          // WSAENOTSOCK, 10038, ��һ�����׽����ϳ�����һ��������
          // �������رռ�����socketʱ����ָô���, ��ʱ��ֻ��Ҫ�򵥵Ĺص�
          // AcceptEx��Ӧ�Ŀͻ���socket����
          TSocketAPI.CloseSocket(LPerIoData.Socket);

        ioConnect:
          // ERROR_CONNECTION_REFUSED, 1225, Զ�̼�����ܾ��������ӡ�
          if (TSocketAPI.CloseSocket(LSocket) = 0) then
          begin
            TriggerConnectFailed(LSocket);
            if Assigned(LPerIoData.Callback) then
              TProc<THandle, Boolean>(LPerIoData.Callback)(LSocket, False);
          end;

        ioReadZero:
          if (TSocketAPI.CloseSocket(LSocket) = 0) then
            TriggerDisconnected(LSocket);

        ioSend:
          begin
            if Assigned(LPerIoData.Callback) then
              TProc<Boolean>(LPerIoData.Callback)(False);

            if (TSocketAPI.CloseSocket(LSocket) = 0) then
              TriggerDisconnected(LSocket);
          end;
      end;
    finally
      FreeIoData(LPerIoData);
    end;

    // ������, ����������ݲ��ǿյ�, ��Ҫ����
    Exit(True);
  end;

  // ���������� StopLoop
  if (LBytes = 0) and (ULONG_PTR(LPerIoData) = SHUTDOWN_FLAG) then Exit(False);

  // ����δ֪ԭ��δ��ȡ���������, ���Ƿ��صĴ��������������
  // ���������Ҫ��������(����True֮��IO�̻߳��ٴε���ProcessIoEvent)
  if (LSocket = 0) or (LPerIoData = nil) then Exit(True);

  try
    case LPerIoData.Action of
      ioAccept  : RequestAcceptComplete(LSocket, LPerIoData);
      ioConnect : RequestConnectComplete(LSocket, LPerIoData);
      ioReadZero: RequestReadZeroComplete(LSocket, LPerIoData);
      ioSend    : RequestSendComplete(LSocket, LPerIoData);
    end;
  finally
    FreeIoData(LPerIoData);
  end;

  Result := True;
end;

end.
